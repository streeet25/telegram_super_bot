# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'ostruct'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/media_jobs'
require_relative '../lib/telegram_instwitter_bot/photo_posts'

class PhotoPostsTest < Minitest::Test
  class FakeApi
    attr_reader :calls
    attr_accessor :fail_media

    def initialize
      @calls = []
    end

    def send_message(**params)
      @calls << [:send_message, params]
    end

    def send_photo(**params)
      raise 'simulated API failure' if fail_media

      @calls << [:send_photo, params]
    end

    def send_media_group(**params)
      raise 'simulated API failure' if fail_media

      @calls << [:send_media_group, params]
    end
  end

  def setup
    @directory = Dir.mktmpdir('photo-post-test-')
    @file = File.join(@directory, 'photos.json')
    @store = PhotoPostStore.new(@file)
    @api = FakeApi.new
    @bot = OpenStruct.new(api: @api)
    @queue = SizedQueue.new(4)
    @scope = '10:20:'
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def photo_entry(id, **attrs)
    { 'message_id' => id, 'file_id' => "photo-#{id}" }.merge(attrs.transform_keys(&:to_s))
  end

  def photo_size(id, width, height)
    OpenStruct.new(file_id: id, width: width, height: height, file_size: width * height)
  end

  def build_message(id, photos: [], **attrs)
    OpenStruct.new({
      message_id: id, chat: OpenStruct.new(id: 10), from: OpenStruct.new(id: 20),
      photo: photos, caption_entities: []
    }.merge(attrs))
  end

  def handle(msg, text = '', addressed: true)
    handle_photo_post_message(@bot, @queue, msg, text, addressed: addressed, bot_username: 'test_bot', store: @store)
  end

  def receive(id, **attrs)
    handle(build_message(id, photos: [photo_size("photo-#{id}", 640, 480)], **attrs))
  end

  def send_command(text = 'собери пост', **attrs)
    handle(build_message(1000, **attrs), text)
  end

  def run_job
    process_media_job(@bot, @queue.pop(true))
  end

  def delivered_media
    @api.calls.select { |method, _| [:send_photo, :send_media_group].include?(method) }
  end

  def test_plain_commands
    ['собери пост', 'Собери подборку из фото', 'собери пост из фотографий', '/post',
     'assemble photo post', 'make a post from photos'].each do |text|
      assert_equal({ count: nil }, photo_post_request(text), text)
    end
  end

  def test_counted_commands_and_invalid_limits
    ['собери пост из последних 3 фото', 'собери последние 3 фотографии',
     'assemble post from last 3 photos'].each do |text|
      assert_equal({ count: 3 }, photo_post_request(text), text)
    end
    assert_equal({ count: 100 }, photo_post_request('собери пост из последних 100 фото'))
    [0, 11, 100].each { |count| assert_raises(PhotoPostError) { @store.reserve(@scope, count) } }
  end

  def test_does_not_steal_existing_video_or_twitter_commands
    ['собери пост из последних 3 видео', 'assemble post from last 3 videos',
     'фото https://x.com/user/status/123', 'собери пост потом', '/help'].each do |text|
      assert_nil photo_post_request(text), text
      refute handle(build_message(1), text), text
    end
  end

  def test_highest_resolution_photo_and_caption_are_saved
    entities = [{ type: 'bold', offset: 0, length: 6 }]
    receive_message = build_message(1, photos: [photo_size('large', 1280, 960), photo_size('small', 90, 90)],
                              caption: 'Привет', caption_entities: entities)
    assert handle(receive_message)
    entry = @store.reserve(@scope, nil).first
    assert_equal 'large', entry['file_id']
    assert_equal 'Привет', entry['caption']
    assert_equal([{ 'type' => 'bold', 'offset' => 0, 'length' => 6 }], entry['caption_entities'])
    assert_equal 0600, File.stat(@file).mode & 0777
  end

  def test_duplicate_message_is_saved_and_acknowledged_once
    2.times { receive(1) }
    assert_equal 1, @store.reserve(@scope, nil).size
    assert_equal 1, @api.calls.size
  end

  def test_same_photo_sent_twice_is_not_deduplicated_by_file_id
    2.times { |id| @store.record(@scope, photo_entry(id, file_id: 'same-photo')) }
    assert_equal 2, @store.reserve(@scope, nil).size
  end

  def test_album_has_one_ack_and_is_sorted_by_message_id
    [3, 1, 2].each { |id| receive(id, media_group_id: 'album-1') }
    assert_equal 1, @api.calls.size
    assert_equal [1, 2, 3], @store.reserve(@scope, nil).map { |entry| entry['message_id'] }
  end

  def test_history_survives_store_restart
    receive(1)
    fresh_store = PhotoPostStore.new(@file)
    assert_equal ['photo-1'], fresh_store.reserve(@scope, nil).map { |entry| entry['file_id'] }
  end

  def test_users_chats_and_topics_are_isolated
    receive(1)
    receive(2, from: OpenStruct.new(id: 21))
    receive(3, chat: OpenStruct.new(id: 11))
    receive(4, message_thread_id: 5)
    assert_equal ['photo-1'], @store.reserve('10:20:', nil).map { |entry| entry['file_id'] }
    assert_equal ['photo-2'], @store.reserve('10:21:', nil).map { |entry| entry['file_id'] }
    assert_equal ['photo-3'], @store.reserve('11:20:', nil).map { |entry| entry['file_id'] }
    assert_equal ['photo-4'], @store.reserve('10:20:5', nil).map { |entry| entry['file_id'] }
  end

  def test_undirected_group_photos_and_commands_are_ignored
    refute handle(build_message(1, photos: [photo_size('unrelated', 640, 480)]), addressed: false)
    refute handle(build_message(2), 'собери пост', addressed: false)
    refute File.exist?(@file)
    assert @queue.empty?
  end

  def test_addressed_group_album_accepts_following_unmentioned_photos
    receive(1, media_group_id: 'group-album')
    assert handle(build_message(2, photos: [photo_size('second', 640, 480)], media_group_id: 'group-album'), addressed: false)
    assert_equal 2, @store.reserve(@scope, nil).size
  end

  def test_reply_to_bot_is_accepted
    reply = OpenStruct.new(from: OpenStruct.new(username: 'test_bot'))
    assert handle(build_message(1, photos: [photo_size('reply-photo', 640, 480)], reply_to_message: reply), addressed: false)
    assert_equal 'reply-photo', @store.reserve(@scope, nil).first['file_id']
  end

  def test_protected_photos_are_not_collected
    receive(1, has_protected_content: true)
    refute File.exist?(@file)
    assert_includes @api.calls.last[1][:text], 'защищено'
  end

  def test_messages_without_user_are_ignored
    refute handle(build_message(1, from: nil), 'собери пост')
  end

  def test_empty_and_insufficient_history_return_help
    send_command
    assert @queue.empty?
    assert_includes @api.calls.last[1][:text], 'Новых фото пока нет'
    receive(1)
    send_command('собери пост из последних 3 фото')
    assert @queue.empty?
    assert_includes @api.calls.last[1][:text], 'только 1'
  end

  def test_album_payload_keeps_order_and_captions_without_uploading_files
    receive(1, caption: 'Подпись', caption_entities: [{ type: 'bold', offset: 0, length: 7 }])
    receive(2)
    send_command
    run_job
    method, params = delivered_media.last
    assert_equal :send_media_group, method
    assert_equal 10, params[:chat_id]
    media = JSON.parse(params[:media])
    assert_equal ['photo-1', 'photo-2'], media.map { |photo| photo['media'] }
    assert media.all? { |photo| photo['type'] == 'photo' }
    assert_equal 'Подпись', media[0]['caption']
    assert_equal 'bold', media[0]['caption_entities'][0]['type']
    refute media[1].key?('caption')
    assert_equal [:chat_id, :media], params.keys.sort
    assert_raises(PhotoPostError) { @store.reserve(@scope, nil) }
  end

  def test_single_photo_uses_send_photo
    receive(1, caption: 'One', caption_entities: [{ type: 'bold', offset: 0, length: 3 }])
    send_command('собери пост из последних 1 фото')
    run_job
    method, params = delivered_media.last
    assert_equal :send_photo, method
    assert_equal 'photo-1', params[:photo]
    assert_equal 'One', params[:caption]
    assert_equal 'bold', JSON.parse(params[:caption_entities])[0]['type']
  end

  def test_topic_is_preserved_in_notices_and_output
    receive(1, message_thread_id: 12)
    send_command('собери пост', message_thread_id: 12)
    run_job
    assert @api.calls.all? { |_, params| params[:message_thread_id] == 12 }
  end

  def test_last_n_selects_only_last_n_and_preserves_earlier_pending
    (1..4).each { |id| receive(id) }
    send_command('собери пост из последних 3 фото')
    run_job
    assert_equal ['photo-2', 'photo-3', 'photo-4'], JSON.parse(delivered_media.last[1][:media]).map { |p| p['media'] }
    assert_equal ['photo-1'], @store.reserve(@scope, nil).map { |p| p['file_id'] }
  end

  def test_success_does_not_recollect_bot_output_or_resend_plain_command
    2.times { |id| receive(id) }
    send_command
    run_job
    send_command
    assert @queue.empty?
    assert_equal 1, delivered_media.size
    # Explicit recent-photo requests may intentionally reuse a previous photo.
    send_command('собери пост из последних 1 фото')
    run_job
    assert_equal 2, delivered_media.size
  end

  def test_command_takes_snapshot_and_leaves_later_photos_pending
    receive(1)
    send_command
    receive(2)
    run_job
    assert_equal 'photo-1', delivered_media.last[1][:photo]
    assert_equal ['photo-2'], @store.reserve(@scope, nil).map { |p| p['file_id'] }
  end

  def test_concurrent_commands_do_not_queue_duplicate_posts
    receive(1)
    2.times { send_command }
    assert_equal 1, @queue.size
    assert_includes @api.calls.last[1][:text], 'Уже собираю'
  end

  def test_full_queue_releases_reservation_without_losing_photos
    receive(1)
    4.times { @queue.push(:existing_job) }
    send_command
    assert_includes @api.calls.last[1][:text], 'Очередь'
    assert_equal 1, @store.reserve(@scope, nil).size
  end

  def test_failed_send_keeps_photos_and_allows_retry
    receive(1)
    receive(2)
    @api.fail_media = true
    send_command
    run_job
    assert_empty delivered_media
    assert_includes @api.calls.last[1][:text], 'Фото сохранены'
    @api.fail_media = false
    send_command
    run_job
    assert_equal 1, delivered_media.size
  end

  def test_more_than_ten_requires_explicit_selection_without_losing_photos
    (1..11).each { |id| receive(id) }
    send_command
    assert @queue.empty?
    assert_includes @api.calls.last[1][:text], 'максимум 10'
    send_command('собери пост из последних 10 фото')
    run_job
    assert_equal 10, JSON.parse(delivered_media.last[1][:media]).size
    assert_equal 1, @store.reserve(@scope, nil).size
  end

  def test_history_limit_does_not_drop_pending_photos
    limited = PhotoPostStore.new(@file, limit: 3)
    [1, 2, 3].each { |id| limited.record(@scope, photo_entry(id)) }
    assert_raises(PhotoPostError) { limited.record(@scope, photo_entry(4)) }
    assert_equal [1, 2, 3], limited.reserve(@scope, nil).map { |p| p['message_id'] }
  end

  def test_old_assembled_entries_are_trimmed_before_pending_photos
    limited = PhotoPostStore.new(@file, limit: 3)
    [1, 2, 3].each { |id| limited.record(@scope, photo_entry(id)) }
    selected = limited.reserve(@scope, 1)
    limited.complete(@scope, selected)
    limited.release(@scope)
    limited.record(@scope, photo_entry(4))
    assert_equal [1, 2, 4], limited.reserve(@scope, nil).map { |p| p['message_id'] }
  end

  def test_corrupt_history_is_not_overwritten
    File.write(@file, '{broken')
    assert_raises(PhotoPostError) { @store.record(@scope, photo_entry(1)) }
    assert_equal '{broken', File.read(@file)
  end

  def test_concurrent_writes_preserve_all_photos
    threads = 10.times.map { |id| Thread.new { @store.record(@scope, photo_entry(id)) } }
    threads.each(&:value)
    assert_equal (0..9).to_a, @store.reserve(@scope, nil).map { |p| p['message_id'] }
  end

  def test_atomic_save_does_not_leave_temporary_files
    receive(1)
    assert_equal ['photos.json'], Dir.children(@directory)
  end
end
