# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/telegram_instwitter_bot/ytdlp'

ENABLE_INSTAGRAM_LEGACY_FETCH = false unless defined?(ENABLE_INSTAGRAM_LEGACY_FETCH)

class InstagramDownloadTest < Minitest::Test
  URL = 'https://www.instagram.com/reel/fixture/?cplk=tracking'

  def with_attempts(outcomes, cookie_args: ['--cookies', '/private/fixture.txt'])
    calls = []
    runner = lambda do |*args, **options|
      calls << [args, options]
      raise 'Unexpected extra download attempt' if outcomes.empty?

      outcome = outcomes.shift
      raise outcome if outcome.is_a?(Exception)

      outcome
    end
    stub(:download_video_with_ytdlp, runner) do
      stub(:ytdlp_cookie_args, cookie_args) do
        capture_io { yield calls }
      end
    end
  end

  def with_legacy
    old = ENABLE_INSTAGRAM_LEGACY_FETCH
    Object.send(:remove_const, :ENABLE_INSTAGRAM_LEGACY_FETCH)
    Object.const_set(:ENABLE_INSTAGRAM_LEGACY_FETCH, true)
    yield
  ensure
    Object.send(:remove_const, :ENABLE_INSTAGRAM_LEGACY_FETCH)
    Object.const_set(:ENABLE_INSTAGRAM_LEGACY_FETCH, old)
  end

  def test_public_success_never_consults_credentials
    with_attempts(['/tmp/public.mp4'], cookie_args: -> { flunk 'Credentials consulted for a public download' }) do |calls|
      assert_equal '/tmp/public.mp4', download_instagram_video_with_ytdlp(URL)
      assert_equal 1, calls.size
      args, options = calls.first
      assert_equal [URL, 'ig_video_'], args
      assert_equal false, options[:use_cookies]
      assert_equal true, options[:require_success]
      assert_equal instagram_ytdlp_formats, options[:format_candidates]
      assert_equal ['--ignore-config', '--no-cookies', '--no-cookies-from-browser'], options[:extra_args]
    end
  end

  def test_extraction_failure_retries_once_with_configured_cookies
    with_attempts([YtdlpExtractionFailed.new('Login required'), '/tmp/auth.mp4']) do |calls|
      assert_equal '/tmp/auth.mp4', download_instagram_video_with_ytdlp(URL)
      assert_equal [false, true], calls.map { |_, options| options[:use_cookies] }
      assert_equal [URL, 'ig_video_'], calls.last.first
      assert_equal ['--ignore-config'], calls.last.last[:extra_args]
      assert calls.all? { |_, options| options[:require_success] }
    end
  end

  def test_browser_cookie_configuration_also_allows_fallback
    with_attempts([YtdlpExtractionFailed.new('Auth'), '/tmp/auth.mp4'], cookie_args: ['--cookies-from-browser', 'firefox']) do |calls|
      assert_equal '/tmp/auth.mp4', download_instagram_video_with_ytdlp(URL)
      assert_equal 2, calls.size
    end
  end

  def test_no_credentials_does_not_repeat_the_same_attempt
    failure = YtdlpExtractionFailed.new('Login required')
    with_attempts([failure], cookie_args: []) do |calls|
      assert_same failure, assert_raises(YtdlpExtractionFailed) { download_instagram_video_with_ytdlp(URL) }
      assert_equal 1, calls.size
    end
  end

  def test_only_final_extraction_error_is_propagated
    failure = YtdlpExtractionFailed.new('Authenticated extraction failed')
    with_attempts([YtdlpExtractionFailed.new('Anonymous extraction failed'), failure]) do |calls|
      assert_same failure, assert_raises(MediaDownloadBlocked) { download_instagram_video_with_ytdlp(URL) }
      assert_equal 2, calls.size
    end
  end

  def test_known_audience_restriction_is_not_lost_to_generic_http_400
    failure = YtdlpExtractionFailed.new('Audience restricted', reason: :audience_restricted)
    with_attempts([failure, YtdlpExtractionFailed.new('HTTP 400')]) do |calls|
      assert_same failure, assert_raises(YtdlpExtractionFailed) { download_instagram_video_with_ytdlp(URL) }
      assert_equal 2, calls.size
    end
  end

  def test_limit_timeout_and_local_errors_do_not_trigger_cookie_retry
    ['probe timeout', 'download timeout', 'too long', 'too large', 'yt-dlp missing'].each do |message|
      failure = MediaDownloadBlocked.new(message)
      with_attempts([failure], cookie_args: -> { flunk 'Safety stop must not consult credentials' }) do |calls|
        assert_same failure, assert_raises(MediaDownloadBlocked) { download_instagram_video_with_ytdlp(URL) }
        assert_equal 1, calls.size
      end
    end
  end

  def test_confirmed_no_video_is_not_retried
    with_attempts([MediaWithoutVideo.new('No video')]) do |calls|
      assert_raises(MediaWithoutVideo) { download_instagram_video_with_ytdlp(URL) }
      assert_equal 1, calls.size
    end
  end

  def test_unexpected_failure_does_not_trigger_authentication
    with_attempts([IOError.new('Local disk error')]) do |calls|
      assert_raises(IOError) { download_instagram_video_with_ytdlp(URL) }
      assert_equal 1, calls.size
    end
  end

  def test_authenticated_safety_stop_is_not_masked_by_anonymous_error
    failure = MediaDownloadBlocked.new('Too large')
    with_attempts([YtdlpExtractionFailed.new('Restricted', reason: :audience_restricted), failure]) do |calls|
      assert_same failure, assert_raises(MediaDownloadBlocked) { download_instagram_video_with_ytdlp(URL) }
      assert_equal 2, calls.size
    end
  end

  def test_legacy_fallback_remains_opt_in_after_both_extraction_failures
    with_legacy do
      stub(:find_executable, '/bin/yt-dlp') do
        with_attempts([YtdlpExtractionFailed.new('Anonymous'), YtdlpExtractionFailed.new('Authenticated')]) do |calls|
          assert_nil download_instagram_video_with_ytdlp(URL)
          assert_equal 2, calls.size
        end
        with_attempts([YtdlpExtractionFailed.new('Anonymous')], cookie_args: []) do |calls|
          assert_nil download_instagram_video_with_ytdlp(URL)
          assert_equal 1, calls.size
        end
      end
      stub(:find_executable, nil) { assert_nil download_instagram_video_with_ytdlp(URL) }
    end
  end

  def test_restriction_classification_is_instagram_specific_and_not_guessed_from_400
    raw = "This content isn't available to everyone: It can't be seen by certain audiences."
    assert_equal :audience_restricted, ytdlp_failure_reason(raw, source_name: 'Instagram')
    assert_nil ytdlp_failure_reason('HTTP Error 400: Bad Request', source_name: 'Instagram')
    assert_nil ytdlp_failure_reason(raw, source_name: 'Threads')
    assert_match(/ограничил доступ/, ytdlp_metadata_failure_message(raw, source_name: 'Instagram'))
    assert_match(/ограничил доступ/, ytdlp_download_failure_message(raw, source_name: 'Instagram'))
  end
end
