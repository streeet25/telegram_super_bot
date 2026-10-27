# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'ostruct'
require 'json'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/ytdlp'

class MediaDownloadBlocked < StandardError; end unless defined?(MediaDownloadBlocked)
class MediaWithoutVideo < StandardError; end unless defined?(MediaWithoutVideo)
YTDLP_PROBE_TIMEOUT_SECONDS = 20 unless defined?(YTDLP_PROBE_TIMEOUT_SECONDS)
YTDLP_DOWNLOAD_TIMEOUT_SECONDS = 90 unless defined?(YTDLP_DOWNLOAD_TIMEOUT_SECONDS)
YTDLP_MAX_FILESIZE_BYTES = 96 * 1024 * 1024 unless defined?(YTDLP_MAX_FILESIZE_BYTES)

class YtdlpDownloadTest < Minitest::Test
  def setup
    @saved_format = ENV.delete('YTDLP_FORMAT')
    @calls, @dirs = [], []
  end

  def teardown
    @saved_format ? ENV['YTDLP_FORMAT'] = @saved_format : ENV.delete('YTDLP_FORMAT')
    @dirs.each { |dir| FileUtils.remove_entry(dir) if Dir.exist?(dir) }
  end

  def download(outcome = :success)
    runner = lambda do |*args, **limits|
      @calls << [args, limits]
      if (index = args.index('-o'))
        file = args[index + 1].sub('%(id)s.%(ext)s', 'fixture.mp4')
        @dirs << File.dirname(file)
        File.write(file, 'merged fixture')
        OpenStruct.new(status: OpenStruct.new(success?: outcome == :success), stdout: '', stderr: '',
                       timed_out: outcome == :timeout, limit_exceeded: outcome == :limit)
      else
        OpenStruct.new(status: OpenStruct.new(success?: true), stdout: '{"id":"fixture"}', timed_out: false)
      end
    end
    stub(:find_executable, '/usr/bin/yt-dlp') do
      stub(:ytdlp_network_args, []) do
        stub(:ytdlp_cookie_args, ['--cookies', '/private/cookies.txt']) do
          stub(:validate_ytdlp_media_info!, nil) do
            stub(:download_filesize_limit_arg, '150M') do
              stub(:download_dir_limit_bytes, 300 * 1024 * 1024) do
                stub(:prepare_video_for_telegram, ->(file, _limit) { file }) do
                  stub(:run_command_with_limits, runner) do
                    download_video_with_ytdlp('https://example.invalid/post', 'yt_formats_', require_success: true)
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def test_merge_selection_preserves_limits_cookies_and_first_entry
    file = download
    assert_equal 'merged fixture', File.read(file)
    assert_equal 2, @calls.size
    args, limits = @calls.last
    assert_equal default_ytdlp_formats.first, args[args.index('-f') + 1]
    assert_includes args[args.index('-f') + 1], '+bestaudio'
    assert_equal 'mp4', args[args.index('--merge-output-format') + 1]
    assert_equal '150M', args[args.index('--max-filesize') + 1]
    assert_equal 90, limits[:timeout_seconds]
    assert_equal 300 * 1024 * 1024, limits[:max_dir_bytes]
    assert_equal File.dirname(file), limits[:watched_dir]
    @calls.each do |command, _|
      assert_equal '1', command[command.index('--playlist-items') + 1]
      assert_equal '/private/cookies.txt', command[command.index('--cookies') + 1]
    end
  end

  def test_explicit_format_override_is_preserved
    ENV['YTDLP_FORMAT'] = 'custom-video+custom-audio'
    download
    args = @calls.last.first
    assert_equal ENV['YTDLP_FORMAT'], args[args.index('-f') + 1]
  end

  def test_oversized_download_is_stopped_and_partial_files_removed
    assert_raises(MediaDownloadBlocked) { download(:limit) }
    assert_equal 1, @dirs.size
    refute Dir.exist?(@dirs.first)
  end

  def test_timeout_is_bounded_and_partial_files_removed
    assert_raises(MediaDownloadBlocked) { download(:timeout) }
    assert_equal 1, @dirs.size
    refute Dir.exist?(@dirs.first)
  end
end
