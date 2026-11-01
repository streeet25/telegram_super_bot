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
    @calls, @dirs, @upload_limits = [], [], []
  end

  def teardown
    @saved_format ? ENV['YTDLP_FORMAT'] = @saved_format : ENV.delete('YTDLP_FORMAT')
    @dirs.each { |dir| FileUtils.remove_entry(dir) if Dir.exist?(dir) }
  end

  def download(outcome = :success, use_cookies: true, extra_args: [], source_name: 'test', info: { 'id' => 'fixture' }, &metadata_block)
    runner = lambda do |*args, **limits|
      @calls << [args, limits]
      if (index = args.index('-o'))
        file = args[index + 1].sub('%(id)s.%(ext)s', 'fixture.mp4')
        @dirs << File.dirname(file)
        File.write(file, 'merged fixture') unless outcome == :filesize_skip
        output = [:filesize_error, :filesize_skip].include?(outcome) ? 'File is larger than max-filesize' : ''
        OpenStruct.new(status: OpenStruct.new(success?: [:success, :filesize_skip].include?(outcome)), stdout: output, stderr: '',
                       timed_out: outcome == :timeout, limit_exceeded: outcome == :limit)
      else
        OpenStruct.new(status: OpenStruct.new(success?: outcome != :probe_error), stdout: JSON.generate(info),
                       stderr: outcome == :probe_error ? 'HTTP Error 400: Bad Request' : '', timed_out: false)
      end
    end
    stub(:find_executable, '/usr/bin/yt-dlp') do
      stub(:ytdlp_network_args, []) do
        stub(:ytdlp_cookie_args, ['--cookies', '/private/cookies.txt']) do
          stub(:validate_ytdlp_media_info!, nil) do
            stub(:download_filesize_limit_arg, '150M') do
              stub(:download_dir_limit_bytes, 300 * 1024 * 1024) do
                stub(:prepare_video_for_telegram, ->(file, limit) { @upload_limits << limit; file }) do
                  stub(:run_command_with_limits, runner) do
                    download_video_with_ytdlp('https://example.invalid/post', 'yt_formats_', require_success: true,
                                             use_cookies: use_cookies, extra_args: extra_args, source_name: source_name, &metadata_block)
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

  def test_metadata_callback_keeps_path_return_value_and_uses_existing_probe
    infos = []
    file = download { |info| infos << info }
    assert File.file?(file)
    assert_equal [{ 'id' => 'fixture' }], infos
    assert_equal 2, @calls.size
  end

  def test_twitter_gif_uses_animation_upload_size_limit_but_regular_video_does_not
    download(source_name: 'Twitter/X', info: { 'id' => 'fixture', 'videomorph_media_type' => 'animation' })
    assert_equal [49 * 1024 * 1024], @upload_limits
    download(source_name: 'Twitter/X')
    assert_equal YTDLP_MAX_FILESIZE_BYTES, @upload_limits.last
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

  def test_anonymous_flags_reach_both_probe_and_download
    flags = ['--ignore-config', '--no-cookies', '--no-cookies-from-browser']
    download(use_cookies: false, extra_args: flags)
    assert_equal 2, @calls.size
    @calls.each do |args, _|
      flags.each { |flag| assert_includes args, flag }
      refute_includes args, '--cookies'
      refute_includes args, '--cookies-from-browser'
      refute_includes args, '/private/cookies.txt'
    end
  end

  def test_metadata_error_is_retryable_but_does_not_download
    assert_raises(YtdlpExtractionFailed) { download(:probe_error) }
    assert_equal 1, @calls.size
    assert_empty @dirs
  end

  def test_exhausted_formats_are_retryable_and_all_partial_files_are_removed
    assert_raises(YtdlpExtractionFailed) { download(:format_error) }
    assert_equal default_ytdlp_formats.size, @dirs.size
    @dirs.each { |dir| refute Dir.exist?(dir) }
  end

  def test_ytdlp_filesize_error_is_not_an_authenticated_retry_candidate
    error = assert_raises(MediaDownloadBlocked) { download(:filesize_error) }
    refute_kind_of YtdlpExtractionFailed, error
    assert_match(/лимит скачивания/, error.message)
    assert_equal default_ytdlp_formats.size, @dirs.size
    @dirs.each { |dir| refute Dir.exist?(dir) }
  end

  def test_ytdlp_successful_filesize_skip_is_also_a_safety_stop
    error = assert_raises(MediaDownloadBlocked) { download(:filesize_skip) }
    refute_kind_of YtdlpExtractionFailed, error
    assert_equal default_ytdlp_formats.size, @dirs.size
    @dirs.each { |dir| refute Dir.exist?(dir) }
  end
end
