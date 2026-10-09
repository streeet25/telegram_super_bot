# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/telegram_instwitter_bot/media_jobs'

class VideoLinkChoicesTest < Minitest::Test
  def parse(text)
    # Production provider regexes are also covered by the native smoke test.
    source = ->(link) { link.start_with?('https://x.com/') ? :twitter : nil }
    stub(:media_source_for_link, source) { extract_video_link_items(text) }
  end

  def test_prefixes_work_with_spaces_mentions_and_mobile_minus_characters
    %w[- − – —].each do |sign|
      ["#{sign}https://x.com/a/1", "@VideoMorph_bot #{sign} https://x.com/a/1"].each do |text|
        assert_equal :skip, parse(text).first[:feed_choice]
      end
    end
    assert_equal :publish, parse('+https://x.com/a/1').first[:feed_choice]
    assert_equal :publish, parse('Вот: + https://x.com/a/1').first[:feed_choice]
  end

  def test_each_url_has_its_own_choice
    items = parse("- https://x.com/a/1\n+ https://x.com/a/2 https://x.com/a/3")
    assert_equal [:skip, :publish, :default], items.map { |item| item[:feed_choice] }
    assert_equal %w[https://x.com/a/1 https://x.com/a/2 https://x.com/a/3], items.map { |item| item[:link] }
  end

  def test_query_and_path_signs_do_not_become_publication_instructions
    assert_equal :default, parse('https://x.com/a-b/1?s=foo+bar').first[:feed_choice]
    assert_equal :default, parse("+\nhttps://x.com/a/1").first[:feed_choice]
    assert_equal :default, parse('text+https://x.com/a/1').first[:feed_choice]
    assert_empty parse('- https://t.me/channel/1')
  end

  def test_conflicting_repeated_url_or_signs_always_prefer_minus
    ['+ - ', '- + '].each { |signs| assert_equal :skip, parse("#{signs}https://x.com/a/1").first[:feed_choice] }
    ['+ https://x.com/a/1 - https://x.com/a/1', '- https://x.com/a/1 + https://x.com/a/1'].each do |text|
      assert_equal 1, parse(text).size
      assert_equal :skip, parse(text).first[:feed_choice]
    end
  end

  def test_failed_download_does_not_shift_a_minus_to_another_item
    items = [{ link: 'missing', source: :twitter, feed_context: { one_off: true } },
             { link: 'private', source: :twitter, feed_context: nil }]
    sent = []
    downloader = ->(item) { item[:link] == 'missing' ? nil : { path: 'file', link: item[:link], source: 'twitter' } }
    sender = ->(*args, **options) { sent << options }
    stub(:download_video_item, downloader) do
      stub(:send_video_file, sender) { process_video_link_batch(nil, 10, items, feed_context: { one_off: true }) }
    end
    assert_equal 1, sent.size
    assert_nil sent.first[:feed_context]
    assert_equal 'private', sent.first[:source_link]
  end
end
