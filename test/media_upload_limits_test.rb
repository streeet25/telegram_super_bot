# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'ostruct'
require_relative '../lib/telegram_instwitter_bot/ytdlp'
require_relative '../lib/telegram_instwitter_bot/media_jobs'

class MediaUploadLimitsTest < Minitest::Test
  class Rejected < StandardError
    attr_reader :data
    def initialize(code); @data = { 'error_code' => code }; super("Telegram #{code}"); end
  end

  def setup
    @dir = Dir.mktmpdir('upload-limits-')
    @path = File.join(@dir, 'original.mp4')
    File.write(@path, 'original')
  end

  def teardown; FileUtils.remove_entry(@dir); end

  def compressed(path, bytes)
    output = File.join(File.dirname(path), 'smaller.mp4')
    File.write(output, 'small')
    File.delete(path)
    assert File.size(output) <= bytes
    output
  end

  def test_safe_configuration_clamps_legacy_96_and_disabled_values
    [nil, '', '0', '-1', '96', 'bad', '500'].each do |value|
      assert_equal 49, TelegramMediaLimits.upload_megabytes(value)
    end
    assert_equal 20, TelegramMediaLimits.upload_megabytes('20')
    assert_equal 49 * 1024 * 1024, TelegramMediaLimits.upload_bytes(nil)
    assert_equal 1000, TelegramMediaLimits.upload_bytes(1000)
  end

  def test_oversized_original_is_compressed_before_any_upload
    File.truncate(@path, 80 * 1024 * 1024) # Sparse fixture, no 80 MB allocation.
    limits = []
    stub(:prepare_video_for_telegram, ->(path, limit) { limits << limit; compressed(path, limit) }) do
      result = with_telegram_upload_size_retry(@path) { |path| assert_equal 'small', File.read(path); :sent }
      assert_equal :sent, result
    end
    assert_equal [49 * 1024 * 1024], limits
  end

  def test_small_file_keeps_original_quality_and_does_not_transcode
    stub(:prepare_video_for_telegram, ->(*) { flunk 'Unnecessary compression' }) do
      assert_equal @path, with_telegram_upload_size_retry(@path) { |path| path }
    end
  end

  def test_explicit_413_retries_once_with_a_strictly_smaller_file
    attempts, limits = [], []
    stub(:prepare_video_for_telegram, ->(path, limit) { limits << limit; compressed(path, limit) }) do
      result = with_telegram_upload_size_retry(@path) do |path|
        attempts << path
        raise Rejected.new(413) if attempts.one?
        :sent
      end
      assert_equal :sent, result
    end
    assert_equal 2, attempts.size
    assert_equal [6], limits
    refute_equal attempts.first, attempts.last
  end

  def test_second_413_stops_and_has_friendly_message
    attempts = 0
    stub(:prepare_video_for_telegram, ->(path, limit) { compressed(path, limit) }) do
      error = assert_raises(Rejected) do
        with_telegram_upload_size_retry(@path) { attempts += 1; raise Rejected.new(413) }
      end
      refute_match(/413|API has returned/, telegram_upload_failure_message(error))
    end
    assert_equal 2, attempts
  end

  def test_timeouts_and_other_rejections_are_never_retried
    [IOError.new('timeout'), Rejected.new(400), Rejected.new(403), Rejected.new(429), Rejected.new(500)].each do |error|
      attempts = 0
      stub(:prepare_video_for_telegram, ->(*) { flunk 'Retry after ambiguous/unrelated error' }) do
        caught = assert_raises(error.class) do
          with_telegram_upload_size_retry(@path) { attempts += 1; raise error }
        end
        assert_same error, caught
      end
      assert_equal 1, attempts
    end
  end

  def test_failed_retry_compression_does_not_repeat_the_oversized_upload
    attempts = 0
    stub(:prepare_video_for_telegram, nil) do
      error = assert_raises(MediaDownloadBlocked) do
        with_telegram_upload_size_retry(@path) { attempts += 1; raise Rejected.new(413) }
      end
      assert_match(/сжать/, error.message)
      assert_equal error.message, telegram_upload_failure_message(error)
    end
    assert_equal 1, attempts
  end

  def test_failed_initial_compression_never_calls_telegram
    File.truncate(@path, 80 * 1024 * 1024)
    stub(:prepare_video_for_telegram, nil) do
      assert_raises(MediaDownloadBlocked) do
        with_telegram_upload_size_retry(@path) { flunk 'Oversized file reached Telegram' }
      end
    end
  end

  def test_proxy_http_413_is_recognized_but_text_alone_is_not
    proxy = Class.new(StandardError) { def response; { status: 413 }; end }.new
    assert telegram_upload_too_large?(proxy)
    refute telegram_upload_too_large?(RuntimeError.new('413 was mentioned in a caption'))
    refute telegram_upload_too_large?(Rejected.new(400))
  end
end
