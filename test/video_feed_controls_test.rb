# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'ostruct'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/video_feed'

class VideoFeedControlsTest < Minitest::Test
  class Api
    attr_accessor :fail_edit, :send_error
    attr_reader :calls
    def initialize; @calls = []; end
    def send_video(**params)
      raise send_error if send_error
      @calls << [:video, params]
      OpenStruct.new(message_id: @calls.size)
    end
    def edit_message_caption(**params)
      raise 'UI failed' if fail_edit
      @calls << [:caption, params]
      true
    end
    def edit_message_text(**params); @calls << [:text, params]; true; end
    def send_message(**params)
      @calls << [:message, params]
      OpenStruct.new(message_id: 900 + @calls.size)
    end
    def answer_callback_query(**params); @calls << [:answer, params]; end
  end

  def setup
    @dir = Dir.mktmpdir('feed-controls-')
    @file = File.join(@dir, 'feed.json')
    @now = 1800000000
    @api = Api.new
    @bot = OpenStruct.new(api: @api)
    @video_feed = build_feed
  end

  def teardown; FileUtils.remove_entry(@dir); end

  def build_feed
    VideoFeed.new(path: @file, api: @api, channel_id: -10042, username: 'pobo4ka_ink', clock: -> { @now })
  end

  def register(choice = :default, private_chat: false, id: 1)
    context = choice == :skip ? nil : @video_feed.submission_context('user:10', private_chat: private_chat, one_off: choice == :publish)
    control = @video_feed.control_context('user:10', chat_id: -20, choice: choice)
    @video_feed.register_control(file_id: "file#{id}", keys: ["key#{id}"], visual: nil, control: control,
                                 context: context, video_message_id: id, caption: 'Видео')
  end

  def activate(job)
    @video_feed.activate_control(job['id'], message_id: job['control_video_id'], kind: 'video')
  end

  def choose(job, action, **attrs)
    @video_feed.choose_control(job['id'], **{ action: action, submitter: 'user:10', chat_id: -20,
                                           message_id: job['control_video_id'] }.merge(attrs))
  end

  def test_timer_starts_after_buttons_are_attached_and_survives_restart
    job = register
    @now += 200
    refute @video_feed.process_next
    activated = activate(job)
    assert_equal @now + 30, activated['next_at']
    @video_feed = build_feed
    @now += 29
    refute @video_feed.process_next
    @now += 1
    assert @video_feed.process_next
    assert_equal 1, @api.calls.count { |name, _| name == :video }
    assert_includes @api.calls.last[1][:caption], 'уже опубликовано'
  end

  def test_default_private_opt_out_does_not_auto_publish_but_button_is_one_off_consent
    @video_feed.set_preference('user:10', enabled: false)
    job = register(:default, private_chat: true)
    activate(job)
    @now += 60
    refute @video_feed.process_next
    assert_equal 'queued', choose(job, 'publish')['status']
    assert @video_feed.process_next
    assert_equal 'off', @video_feed.preference('user:10')
  end

  def test_minus_stays_private_until_an_explicit_later_button_click
    job = register(:skip)
    activate(job)
    @now += 60
    refute @video_feed.process_next
    assert_equal 'awaiting_choice', @video_feed.control_snapshot(job['id'])['status']
    choose(job, 'publish')
    assert @video_feed.process_next
    assert_nil @video_feed.preference('user:10')
  end

  def test_plus_retains_immediate_publication_even_before_keyboard_attachment
    job = register(:publish, private_chat: true)
    assert_equal 0, job['next_at']
    assert @video_feed.process_next
    assert_equal 'sent', choose(job, 'skip')['status']
  end

  def test_cancel_stays_cancelled_after_generic_consent_and_restart
    job = register(:default, private_chat: true)
    activate(job)
    assert_equal 'opted_out', choose(job, 'skip')['status']
    @video_feed.set_preference('user:10', enabled: true, consent_request: job['consent_request'])
    @video_feed = build_feed
    @now += 60
    refute @video_feed.process_next
  end

  def test_generic_consent_starts_a_fresh_30_second_window
    job = register(:default, private_chat: true)
    activate(job)
    @now += 100
    @video_feed.set_preference('user:10', enabled: true, consent_request: job['consent_request'])
    refute @video_feed.process_next
    @now += 30
    assert @video_feed.process_next
  end

  def test_click_can_publish_before_timer_but_repeated_clicks_never_resend
    job = register
    activate(job)
    choose(job, 'publish')
    choose(job, 'publish')
    assert @video_feed.process_next
    assert_equal 'sent', choose(job, 'publish')['status']
    refute @video_feed.process_next
  end

  def test_group_buttons_are_bound_to_sender_chat_and_message
    job = register
    activate(job)
    [{ submitter: 'user:11' }, { chat_id: -21 }, { message_id: 2 }].each do |bad|
      assert_raises(VideoFeedError) { choose(job, 'skip', **bad) }
    end
    assert_equal 'queued', @video_feed.control_snapshot(job['id'])['status']
  end

  def test_expiry_and_moderator_ban_cannot_be_bypassed
    job = register(:publish)
    @video_feed.process_next
    message_id = @api.calls.find { |name, _| name == :video } && 1
    @video_feed.moderate('ban', message_id, actor_id: 42)
    assert_raises(VideoFeedError) { choose(job, 'publish') }
    @now += 24 * 3600
    assert_raises(VideoFeedError) { choose(job, 'skip') }
  end

  def test_private_records_do_not_block_someone_elses_duplicate
    register(:skip)
    assert_equal :queued, @video_feed.enqueue(file_id: 'other', keys: ['key1'], submitter: 'user:20')
  end

  def test_dedup_is_preserved_when_publishing_a_previously_private_video
    job = register(:skip)
    @video_feed.enqueue(file_id: 'other', keys: ['key1'], submitter: 'user:20')
    @video_feed.process_next
    assert_equal 'duplicate', choose(job, 'publish')['status']
    refute @video_feed.process_next
  end

  def test_unconfirmed_delivery_cannot_be_cancelled_or_retried_by_buttons
    job = register(:publish)
    @api.send_error = IOError.new('network')
    @video_feed.process_next
    assert_equal 'uncertain', choose(job, 'skip')['status']
    assert_equal 'uncertain', choose(job, 'publish')['status']
    refute @video_feed.process_next
  end

  def test_failed_keyboard_attachment_does_not_start_auto_publication
    @api.fail_edit = true
    message = OpenStruct.new(message_id: 4, chat: OpenStruct.new(id: -20),
                             video: OpenStruct.new(file_id: 'file', file_unique_id: 'unique'))
    attach_video_feed_control(@bot, message, control: { submitter: 'user:10', chat_id: -20, choice: :default },
                              context: @video_feed.submission_context('user:10', private_chat: false),
                              keys: ['key'], visual: nil, caption: 'Видео')
    @now += 60
    refute @video_feed.process_next
    assert_equal 1, @video_feed.stats['queued']
  end

  def test_album_controls_reply_silently_to_the_exact_video_and_bind_reply_id
    message = OpenStruct.new(message_id: 4, message_thread_id: 8, chat: OpenStruct.new(id: -20),
                             video: OpenStruct.new(file_id: 'file', file_unique_id: 'unique'))
    attach_video_feed_control(@bot, message, control: { submitter: 'user:10', chat_id: -20, choice: :skip },
                              context: nil, keys: ['key'], visual: nil, caption: 'Видео 2 из подборки', album: true)
    params = @api.calls.last[1]
    assert params[:disable_notification]
    assert_equal 8, params[:message_thread_id]
    assert_equal({ 'message_id' => 4 }, JSON.parse(params[:reply_parameters]))
    token = JSON.parse(params[:reply_markup])['inline_keyboard'][0][0]['callback_data'].split(':').last
    assert_equal 901, @video_feed.control_snapshot(token)['control_message_id']
    assert_raises(VideoFeedError) { @video_feed.choose_control(token, action: 'publish', submitter: 'user:10', chat_id: -20, message_id: 4) }
    assert_equal 'queued', @video_feed.choose_control(token, action: 'publish', submitter: 'user:10', chat_id: -20, message_id: 901)['status']
  end

  def test_callback_acknowledges_and_updates_only_its_own_control
    job = register
    activate(job)
    callback = OpenStruct.new(id: 'cb', data: "feed_item:skip:#{job['id']}", from: OpenStruct.new(id: 10, is_bot: false),
                              message: OpenStruct.new(message_id: 1, chat: OpenStruct.new(id: -20)))
    assert handle_video_feed_control_callback(@bot, callback)
    assert_equal 'opted_out', @video_feed.control_snapshot(job['id'])['status']
    assert_equal [:answer, :caption], @api.calls.map(&:first)
    assert_operator callback.data.bytesize, :<=, 64
  end

  def test_timer_race_never_reports_cancelled_after_sending
    job = register
    activate(job)
    @now += 30
    publication = Thread.new { @video_feed.process_next }
    cancellation = Thread.new { choose(job, 'skip') }
    result = cancellation.value
    publication.value
    sends = @api.calls.count { |name, _| name == :video }
    assert_equal(result['status'] == 'sent' ? 1 : 0, sends)
    assert_includes %w[sent opted_out], result['status']
  end

  def test_failed_choice_persistence_does_not_claim_cancellation
    job = register
    activate(job)
    saved = File.read(@file)
    File.delete(@file)
    Dir.mkdir(@file)
    assert_raises(SystemCallError) { choose(job, 'skip') }
    assert_equal 'queued', @video_feed.control_snapshot(job['id'])['status']
    Dir.rmdir(@file)
    File.write(@file, saved)
  end

  def test_global_opt_out_cancels_new_control_timer_without_resetting_history
    job = register
    activate(job)
    @video_feed.set_preference('user:10', enabled: false)
    @video_feed = build_feed
    @now += 60
    refute @video_feed.process_next
    assert_equal 'opted_out', @video_feed.control_snapshot(job['id'])['status']
  end

  def test_expired_private_controls_are_removed
    job = register(:skip)
    activate(job)
    @now += 24 * 3600
    refute @video_feed.process_next
    assert_nil @video_feed.control_snapshot(job['id'])
  end
end
