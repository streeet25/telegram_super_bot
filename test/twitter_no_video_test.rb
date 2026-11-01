# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'ostruct'
require 'uri'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/ytdlp'
require_relative '../lib/telegram_instwitter_bot/twitter'
require_relative '../lib/telegram_instwitter_bot/media_jobs'

YTDLP_PROBE_TIMEOUT_SECONDS = 20 unless defined?(YTDLP_PROBE_TIMEOUT_SECONDS)

class TwitterNoVideoTest < Minitest::Test
  URL = 'https://x.com/example/status/1234567890123456789?s=20'

  def run_batch(error_text, timed_out: false)
    messages, calls = [], []
    api = Object.new
    api.define_singleton_method(:send_message) { |**options| messages << options }
    bot = OpenStruct.new(api: api)
    runner = lambda do |*args, **limits|
      calls << [args, limits]
      OpenStruct.new(status: OpenStruct.new(success?: false), stderr: error_text, stdout: '', timed_out: timed_out)
    end
    stub(:find_executable, '/usr/bin/yt-dlp') do
      stub(:ytdlp_network_args, []) do
        stub(:ytdlp_cookie_args, ['--cookies', '/private/fixture.txt']) do
          stub(:run_command_with_limits, runner) do
            capture_io { process_video_link_batch(bot, 123, [{ source: :twitter, link: URL }]) }
          end
        end
      end
    end
    [messages, calls]
  end

  def test_confirmed_text_post_is_silent_and_does_not_start_download
    messages, calls = run_batch('ERROR: [videomorph:twitter] 123: No video could be found in this tweet')
    assert_empty messages
    assert_equal 1, calls.size
    args, limits = calls.first
    assert_includes args, '--skip-download'
    refute_includes args, '-o'
    assert_equal 20, limits[:timeout_seconds]
    assert_equal 'https://twitter.com/example/status/1234567890123456789', args.last
  end

  def test_plugin_is_enabled_without_changing_cookies_or_first_video_rule
    _, calls = run_batch('No video could be found in this tweet')
    args = calls.first.first
    assert_includes args, '--no-plugin-dirs'
    root = args[args.index('--plugin-dirs') + 1]
    assert File.file?(File.join(root, 'videomorph/yt_dlp_plugins/extractor/videomorph_twitter.py'))
    assert_equal '/private/fixture.txt', args[args.index('--cookies') + 1]
    assert_equal '1', args[args.index('--playlist-items') + 1]
  end

  def test_real_access_network_and_extractor_errors_still_notify
    ['HTTP Error 403: Forbidden', 'HTTP Error 429: Too Many Requests',
     'HTTP Error 404: This tweet is not available', 'Twitter post metadata unavailable',
     'Unsupported URL: https://example.invalid/broken-player'].each do |error|
      messages, calls = run_batch(error)
      assert_equal 1, messages.size, error
      assert_equal 123, messages.first[:chat_id]
      assert_equal 1, calls.size
    end
  end

  def test_timeout_is_still_reported
    messages, = run_batch('', timed_out: true)
    assert_equal 1, messages.size
    assert_match(/слишком долго/, messages.first[:text])
  end

  def test_text_post_does_not_stop_other_videos_in_a_batch
    sends = []
    items = [{ source: :twitter, link: 'text' }, { source: :twitter, link: 'video' }]
    downloader = lambda do |item|
      raise MediaWithoutVideo, 'No video' if item[:link] == 'text'

      { path: '/tmp/fixture.mp4', source: 'twitter', link: item[:link], metadata: {} }
    end
    stub(:download_video_item, downloader) do
      stub(:send_video_file, ->(*args, **_) { sends << args }) do
        stub(:safe_send_message, ->(*) { flunk 'Text posts must stay silent' }) do
          capture_io { process_video_link_batch(nil, 123, items) }
        end
      end
    end
    assert_equal 1, sends.size
    assert_equal '/tmp/fixture.mp4', sends.first[2]
  end
end
