# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'ostruct'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/ytdlp'
require_relative '../lib/telegram_instwitter_bot/media_jobs'
require_relative '../lib/telegram_instwitter_bot/video_feed'
require_relative '../lib/telegram_instwitter_bot/youtube_shorts'

TWITTER_REGEX = %r{https?://(?:x|twitter)\.com/} unless defined?(TWITTER_REGEX)
INSTAGRAM_REGEX = %r{https?://(?:www\.)?instagram\.com/} unless defined?(INSTAGRAM_REGEX)

class YoutubeVideoTest < Minitest::Test
  ID = 'BaW_jenozKc'
  URL = "https://www.youtube.com/watch?v=#{ID}"

  def variants
    [URL, "http://m.youtube.com/watch?si=track&v=#{ID}&list=playlist&t=42",
     "https://youtu.be/#{ID}?si=track", "https://www.youtube.com/shorts/#{ID}/?feature=share",
     "https://www.youtube.com/embed/#{ID}", "https://music.youtube.com/watch?v=#{ID}"]
  end

  def test_normalizes_all_supported_variants_to_one_video
    variants.each do |url|
      assert_equal ID, youtube_video_reference(url)[:id]
      assert_equal URL, youtube_video_reference(url)[:url]
    end
  end

  def test_rejects_playlists_channels_ambiguous_urls_and_lookalike_hosts
    ['https://youtube.com/playlist?list=123', 'https://youtube.com/@channel', 'https://youtube.com/watch',
     'https://youtu.be/', 'https://youtube.com/watch?v=abc&v=def', 'https://youtube.com/watch?v=abc%2Fdef',
     'https://youtube.com.evil.test/watch?v=abc', 'https://evil.test/youtube.com/shorts/abc',
     'https://youtube.com@evil.test/watch?v=abc', 'https://user@youtube.com/watch?v=abc',
     'https://youtube.com:8080/watch?v=abc', 'file:///youtube.com/watch?v=abc', 'not a URL'].each do |url|
      assert_nil youtube_video_reference(url), url
    end
  end

  def test_five_minutes_is_inclusive_but_not_one_fraction_more
    [1, 299.99, 300, '300.0'].each { |duration| validate_youtube_duration!(duration) }
    [300.01, 301, 600].each do |duration|
      error = assert_raises(MediaDownloadBlocked) { validate_youtube_duration!(duration) }
      assert_match(/длиннее 5 минут/, error.message)
    end
  end

  def test_missing_invalid_or_nonfinite_duration_fails_closed
    [nil, '', 0, -1, 'unknown', Float::NAN, Float::INFINITY].each do |duration|
      assert_raises(MediaDownloadBlocked) { validate_youtube_duration!(duration) }
    end
  end

  def with_download(metadata_duration:, file_duration:)
    path = nil
    runner = lambda do |url, prefix, **options, &block|
      assert_equal URL, url
      assert_equal 'yt_video_', prefix
      assert_equal true, options[:require_success]
      block.call('duration' => metadata_duration)
      path = File.join(Dir.mktmpdir(prefix), 'video.mp4')
      File.write(path, 'fixture')
      path
    end
    probe = ->(file) { assert_equal path, file; { 'format' => { 'duration' => file_duration } } }
    stub(:download_video_with_ytdlp, runner) do
      stub(:probe_media_streams, probe) { yield -> { path } }
    end
  ensure
    cleanup_media_path(path) if path
  end

  def test_metadata_limit_is_checked_before_downloading_bytes
    with_download(metadata_duration: 301, file_duration: '10') do |path|
      assert_raises(MediaDownloadBlocked) { download_youtube_video(URL) }
      assert_nil path.call
    end
  end

  def test_final_file_duration_is_checked_and_rejected_file_removed
    [nil, '300.1', '900'].each do |duration|
      with_download(metadata_duration: 299, file_duration: duration) do |path|
        assert_raises(MediaDownloadBlocked) { download_youtube_video(URL) }
        refute Dir.exist?(File.dirname(path.call))
      end
    end
  end

  def test_successful_file_is_kept_for_telegram_delivery
    with_download(metadata_duration: 300, file_duration: '300.0') do |path|
      result = download_youtube_video(URL)
      assert_equal path.call, result
      assert File.file?(result)
    end
  end

  def test_shorts_use_same_five_minute_limit
    with_download(metadata_duration: 301, file_duration: '301') do
      assert_raises(MediaDownloadBlocked) { download_youtube_shorts_video("https://www.youtube.com/shorts/#{ID}") }
    end
  end

  def test_unavailable_youtube_is_a_visible_error_not_a_silent_text_post_skip
    stub(:download_video_with_ytdlp, ->(*) { raise MediaWithoutVideo, 'no video' }) do
      error = assert_raises(MediaDownloadBlocked) { download_youtube_video(URL) }
      assert_match(/YouTube не отдал видео/, error.message)
    end
  end

  def test_equivalent_links_merge_choices_and_minus_wins_without_changing_other_links
    items = extract_video_link_items("+ #{variants[2]} - #{URL} https://www.instagram.com/reel/fixture/ #{URL}&si=x")
    assert_equal [:youtube, :instagram], items.map { |item| item[:source] }
    assert_equal [:skip, :default], items.map { |item| item[:feed_choice] }
    assert_equal URL, items.first[:link]
    assert_equal 'https://www.instagram.com/reel/fixture/', items.last[:link]
    assert_equal :youtube_shorts, extract_video_link_items(variants[3]).first[:source]
  end

  def test_canonical_feed_fingerprint_matches_older_shorts_receipts
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'video.mp4'); File.write(path, 'fixture')
      expected = "url:#{Digest::SHA256.hexdigest("yt:#{ID}")}"
      variants.each { |url| assert_includes video_feed_keys(url, path), expected }
      refute_equal video_feed_keys(URL, path), video_feed_keys('https://youtube.com/watch?v=another', path)
    end
  end

  def test_delivery_preserves_per_video_controls_and_excludes_overlong_clip
    items = [{ source: :youtube, link: 'long', feed_control: :ignored },
             { source: :youtube, link: URL, feed_control: :control, feed_context: { one_off: true } }]
    sends, notices = [], []
    downloader = lambda do |item|
      raise MediaDownloadBlocked, 'YouTube-видео длиннее 5 минут' if item[:link] == 'long'
      { path: 'fixture', source: 'youtube', link: item[:link] }
    end
    stub(:download_video_item, downloader) do
      stub(:safe_send_message, ->(*args) { notices << args.last }) do
        stub(:send_video_file, ->(*args, **opts) { sends << opts }) { capture_io { process_video_link_batch(nil, 1, items) } }
      end
    end
    assert_equal 1, sends.size
    assert_equal 1, notices.size
    assert_equal :control, sends.first[:feed_control]
    assert_equal({ one_off: true }, sends.first[:feed_context])
  end
end
