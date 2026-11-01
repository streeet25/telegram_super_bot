# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'
require 'uri'
require_relative '../lib/telegram_instwitter_bot/ytdlp'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/twitter'
require_relative '../lib/telegram_instwitter_bot/media_jobs'

class TwitterGifTest < Minitest::Test
  def test_metadata_marker_reaches_item_without_changing_downloader_path_contract
    info = { 'videomorph_media_type' => 'animation' }
    runner = ->(*_args, **_options, &block) { block.call(info); '/tmp/gif.mp4' }
    stub(:download_video_with_ytdlp, runner) do
      stub(:video_upload_metadata, {}) do
        item = download_video_item(source: :twitter, link: 'https://x.com/test/status/123')
        assert_equal 'animation', item[:media_type]
        assert_equal '/tmp/gif.mp4', item[:path]
      end
    end
  end

  def test_silent_short_video_is_not_guessed_to_be_a_gif
    runner = ->(*_args, **_options, &block) { block.call('duration' => 2, 'acodec' => 'none'); '/tmp/video.mp4' }
    stub(:download_video_with_ytdlp, runner) do
      stub(:video_upload_metadata, {}) do
        assert_equal 'video', download_video_item(source: :twitter, link: 'https://x.com/test/status/123')[:media_type]
      end
    end
  end

  def test_mixed_batch_preserves_order_and_never_places_gif_in_video_album
    sequence = %w[video video animation video animation animation video video]
    items = sequence.each_with_index.map { |kind, index| { source: :twitter, link: index.to_s, kind: kind } }
    sent = []
    downloader = ->(item) { { path: item[:link], link: item[:link], source: 'twitter', media_type: item[:kind] } }
    stub(:download_video_item, downloader) do
      stub(:send_video_file, ->(_bot, _chat, path, *_rest, **_opts) { sent << [:video, path] }) do
        stub(:send_animation_file, ->(_bot, _chat, path, *_rest, **_opts) { sent << [:animation, path] }) do
          stub(:send_video_album, ->(_bot, _chat, videos, **_opts) { sent << [:album, videos.map { |v| v[:path] }] }) do
            process_video_link_batch(nil, 1, items)
          end
        end
      end
    end
    assert_equal [[:album, %w[0 1]], [:animation, '2'], [:video, '3'], [:animation, '4'], [:animation, '5'], [:album, %w[6 7]]], sent
  end

  def test_legacy_twitter_job_also_routes_gif_as_animation
    stub(:download_video_item, { path: '/tmp/gif.mp4', source: 'twitter', media_type: 'animation' }) do
      stub(:send_animation_file, ->(*_args, **_opts) { @animation_sent = true }) do
        stub(:send_video_file, ->(*) { flunk 'GIF must not use sendVideo' }) do
          capture_io { process_media_job(nil, type: :twitter_video, chat_id: 1, link: 'fixture') }
        end
      end
    end
    assert @animation_sent
  end
end
