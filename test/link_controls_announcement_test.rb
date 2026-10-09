# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'ostruct'
require_relative '../lib/telegram_instwitter_bot/link_controls_announcement'

class LinkControlsAnnouncementTest < Minitest::Test
  class Api
    attr_reader :calls
    attr_accessor :error
    def initialize; @calls = []; end
    def send_message(**params)
      @calls << params
      raise error if error
      OpenStruct.new(message_id: @calls.size)
    end
  end

  def setup
    @dir = Dir.mktmpdir('announcement-test-')
    @path = File.join(@dir, 'announcement.json')
    @api = Api.new
    @now = 100
    @runner = LinkControlsAnnouncement.new(path: @path, api: @api, clock: -> { @now }, pause: -> {})
  end

  def teardown; FileUtils.remove_entry(@dir); end

  def test_announces_once_per_recipient_and_preserves_language
    assert_equal({ 'sent' => 2 }, @runner.run('10' => 'ru', '11' => 'en'))
    assert_includes @api.calls.first[:text], 'Апдейт'
    assert_includes @api.calls.last[:text], 'update'
    assert @api.calls.all? { |call| call[:chat_id] > 0 && call[:text].length <= 4096 }
    assert_equal 0600, File.stat(@path).mode & 0777
    @runner.run('10' => 'ru', '11' => 'en', '12' => 'ru')
    assert_equal 2, @api.calls.size # A rerun retains the original recipient snapshot.
  end

  def test_uncertain_delivery_is_not_resent
    @api.error = IOError.new('network failed')
    assert_equal({ 'uncertain' => 1 }, @runner.run('10' => 'ru'))
    @api.error = nil
    @runner.run('10' => 'ru')
    assert_equal 1, @api.calls.size
  end

  def test_even_a_hand_edited_recipient_snapshot_cannot_target_groups
    assert_raises(RuntimeError) { @runner.run('-10042' => 'ru') }
    assert_empty @api.calls
  end

  def test_blocked_recipient_is_not_retried
    error = Class.new(StandardError) { def data; { 'error_code' => 403 }; end }
    @api.error = error.new
    assert_equal({ 'unavailable' => 1 }, @runner.run('10' => 'ru'))
    @runner.run('10' => 'ru')
    assert_equal 1, @api.calls.size
  end

  def test_rate_limit_pauses_every_recipient_until_retry_after
    error = Class.new(StandardError) { def data; { 'error_code' => 429, 'parameters' => { 'retry_after' => 20 } }; end }
    @api.error = error.new
    assert_equal({ 'rate_limited' => 1, 'pending' => 1 }, @runner.run('10' => 'ru', '11' => 'en'))
    @runner.run({})
    assert_equal 1, @api.calls.size
    @now += 20
    @api.error = nil
    assert_equal({ 'sent' => 2 }, @runner.run({}))
  end

  def test_recipient_collection_excludes_group_channel_and_invalid_ids
    File.write(File.join(@dir, 'user_languages.json'), JSON.generate('10' => 'en', '-10042' => 'ru'))
    File.write(File.join(@dir, 'media_history.json'), JSON.generate('11' => [], '-20' => []))
    File.write(File.join(@dir, 'photo_history.json'), JSON.generate('12:12:' => [], '-30:99:' => []))
    File.write(File.join(@dir, 'video_feed.json'), JSON.generate(preferences: { 'user:13' => 'off' }, jobs: [
      { submitter: 'user:10' }, { submitter: 'user:14' }, { submitter: 'channel:-100' }]))
    assert_equal({ '10' => 'en', '11' => 'ru', '12' => 'ru', '13' => 'ru', '14' => 'ru' }, LinkControlsAnnouncement.recipients(@dir))
  end
end
