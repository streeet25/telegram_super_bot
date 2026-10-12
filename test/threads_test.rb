# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'ostruct'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/threads'
require_relative '../lib/telegram_instwitter_bot/ytdlp'
require_relative '../lib/telegram_instwitter_bot/media_jobs'

class MediaDownloadBlocked < StandardError; end unless defined?(MediaDownloadBlocked)
class MediaWithoutVideo < StandardError; end unless defined?(MediaWithoutVideo)
YTDLP_PROBE_TIMEOUT_SECONDS = 20 unless defined?(YTDLP_PROBE_TIMEOUT_SECONDS)
YTDLP_DOWNLOAD_TIMEOUT_SECONDS = 90 unless defined?(YTDLP_DOWNLOAD_TIMEOUT_SECONDS)
YTDLP_MAX_FILESIZE_BYTES = 96 * 1024 * 1024 unless defined?(YTDLP_MAX_FILESIZE_BYTES)

class ThreadsTest < Minitest::Test
  def test_normalizes_both_domains_tracking_and_http
    %w[threads.net www.threads.net threads.com www.threads.com].each do |host|
      assert_equal 'https://www.threads.com/@katia_lok/post/DeWshaKHBhY',
                   normalize_threads_url("http://#{host}/@katia_lok/post/DeWshaKHBhY/?x=1#test")
    end
    assert_equal 'https://www.threads.com/t/Ab-_123', normalize_threads_url('https://threads.net/t/Ab-_123')
    assert_equal 'https://www.threads.com/share/Ab-_123', normalize_threads_url('https://threads.com/share/Ab-_123/')
  end

  def test_rejects_profiles_bad_paths_and_lookalike_domains
    %w[https://threads.com/@person https://threads.com/@person/post/
       https://threads.com.evil.test/@p/post/abc https://evil.test/https://threads.com/t/abc
       https://threads.com@evil.test/t/abc https://threads.com:8443/t/abc
       https://threads.com/t/abc/extra https://threads.com/search?q=abc
       file:///threads.com/t/abc].each { |url| assert_nil normalize_threads_url(url), url }
  end

  def test_downloader_enables_only_local_plugin_without_cookies
    call = nil
    fake = ->(*args, **options) { call = [args, options]; '/tmp/video.mp4' }
    stub(:download_video_with_ytdlp, fake) do
      assert_equal '/tmp/video.mp4', download_threads_video('http://threads.net/t/abc?test=1')
    end
    assert_equal ['https://www.threads.com/t/abc', 'threads_video_'], call[0]
    assert_equal false, call[1][:use_cookies]
    assert_equal true, call[1][:require_success]
    assert_equal 'Threads', call[1][:source_name]
    assert_equal ['best[ext=mp4]/bestvideo[ext=mp4]/best/bestvideo'], call[1][:format_candidates]
    options = call[1][:extra_args]
    assert File.file?(File.join(options[options.index('--plugin-dirs') + 1], 'videomorph/yt_dlp_plugins/extractor/videomorph_threads.py'))
    assert_includes options, '--ignore-config'
    assert_includes options, '--no-plugin-dirs'
  end

  def test_no_video_has_a_clear_response_and_invalid_urls_do_not_download
    stub(:download_video_with_ytdlp, ->(*) { raise MediaWithoutVideo }) do
      assert_match(/нет собственного видео/, assert_raises(MediaDownloadBlocked) { download_threads_video('https://threads.com/t/abc') }.message)
      assert_match(/Нужна ссылка/, assert_raises(MediaDownloadBlocked) { download_threads_video('https://threads.com/@p') }.message)
    end
  end

  def test_batch_routes_threads_and_cleans_the_whole_temp_directory
    dir = Dir.mktmpdir('threads_video_test_')
    file = File.join(dir, 'clip.mp4')
    File.write(file, 'video')
    File.write(File.join(dir, 'leftover.part'), 'partial')
    stub(:download_threads_video, file) do
      stub(:video_upload_metadata, { duration: 2 }) do
        item = download_video_item(link: 'https://threads.com/t/abc', source: :threads)
        assert_equal 'threads', item[:source]
        assert_equal file, item[:path]
      end
    end
    cleanup_media_path(file)
    refute Dir.exist?(dir)
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  def test_threads_errors_do_not_request_unused_instagram_cookies
    refute_match(/cookies/, ytdlp_metadata_failure_message('HTTP Error 403', source_name: 'Threads'))
    refute_match(/cookies/, ytdlp_download_failure_message('HTTP Error 403', source_name: 'Threads'))
    assert_match(/cookies/, ytdlp_download_failure_message('HTTP Error 403', source_name: 'Instagram'))
  end

  def test_plugin_options_reach_both_probe_and_download
    calls = []
    runner = lambda do |*args, **_limits|
      calls << args
      output = args.index('-o')
      File.write(args[output + 1].sub('%(id)s.%(ext)s', 'abc.mp4'), 'video') if output
      OpenStruct.new(status: OpenStruct.new(success?: true), stdout: '{"id":"abc"}', timed_out: false, limit_exceeded: false)
    end
    stub(:find_executable, '/bin/yt-dlp') do
      stub(:ytdlp_network_args, []) do
        stub(:ytdlp_cookie_args, -> { flunk 'Threads must not open the shared cookie jar' }) do
          stub(:validate_ytdlp_media_info!, nil) do
            stub(:download_filesize_limit_arg, '150M') do
              stub(:download_dir_limit_bytes, 300_000_000) do
                stub(:prepare_video_for_telegram, ->(file, _limit) { file }) do
                  stub(:run_command_with_limits, runner) { @download = download_threads_video('https://threads.com/t/abc') }
                end
              end
            end
          end
        end
      end
    end
    assert_equal 2, calls.size
    calls.each do |args|
      assert_includes args, '--plugin-dirs'
      refute_includes args, '--cookies'
      assert_equal '1', args[args.index('--playlist-items') + 1]
    end
  ensure
    cleanup_media_path(@download)
  end
end
