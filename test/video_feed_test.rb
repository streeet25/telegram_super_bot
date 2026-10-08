# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'ostruct'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/video_feed'

class VideoFeedTest < Minitest::Test
  class ApiError < StandardError
    attr_reader :data

    def initialize(code, description = '', retry_after = nil)
      @data = { 'error_code' => code, 'description' => description, 'parameters' => { 'retry_after' => retry_after } }
    end
  end

  class FakeApi
    attr_reader :calls
    attr_accessor :error, :member, :before_send

    def initialize
      @calls = []
      @member = OpenStruct.new(status: 'creator')
    end

    def send_video(**params)
      @before_send.call if @before_send
      raise @error if @error

      @calls << [:send_video, params]
      OpenStruct.new(message_id: @calls.count { |name, _| name == :send_video })
    end

    def delete_message(**params)
      raise @error if @error

      @calls << [:delete_message, params]
      true
    end

    def send_message(**params)
      @calls << [:send_message, params]
    end

    def answer_callback_query(**params)
      @calls << [:answer_callback_query, params]
    end

    def get_chat_member(**params)
      @calls << [:get_chat_member, params]
      @member
    end
  end

  def setup
    @directory = Dir.mktmpdir('video-feed-test-')
    @file = File.join(@directory, 'feed.json')
    @now = 1_800_000_000
    @api = FakeApi.new
    @feed = new_feed
    @bot = OpenStruct.new(api: @api)
    @video_feed = @feed
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def new_feed
    VideoFeed.new(path: @file, api: @api, channel_id: -10042, username: 'pobo4ka_ink', clock: -> { @now })
  end

  def enqueue(id = '1', user = 'user:10', **options)
    @feed.enqueue(file_id: "file-#{id}", keys: ["key-#{id}"], submitter: user, **options)
  end

  def build_message(text, **attrs)
    OpenStruct.new({ chat: OpenStruct.new(id: 10, type: 'private'),
      from: OpenStruct.new(id: 10, is_bot: false), text: text }.merge(attrs))
  end

  def command(text, **attrs)
    handle_video_feed_command(@bot, build_message(text, **attrs), text)
  end

  def last_reply
    @api.calls.select { |name, _| name == :send_message }.last[1][:text]
  end

  def test_enqueue_persists_and_uses_private_permissions
    assert_equal :queued, enqueue
    assert_equal 0600, File.stat(@file).mode & 0777
    @feed = new_feed
    assert_equal 1, @feed.stats['queued']
    assert @feed.process_next
    assert_equal({ chat_id: -10042, video: 'file-1', supports_streaming: true }, @api.calls.last[1])
    assert_equal 1, new_feed.stats['sent']
    refute @feed.process_next
  end

  def test_dedup_pending_sent_and_restarted
    enqueue
    assert_equal :duplicate, enqueue
    @feed.process_next
    assert_equal :duplicate, enqueue('1', 'user:20')
    @feed = new_feed
    assert_equal :duplicate, enqueue
    assert_equal :duplicate, @feed.enqueue(file_id: 'different', keys: ['new', 'key-1'], submitter: 'user:20')
  end

  def test_atomic_concurrent_dedup
    results = 8.times.map { Thread.new { enqueue } }.map(&:value)
    assert_equal 1, results.count(:queued)
    assert_equal 7, results.count(:duplicate)
  end

  def test_api_rate_limit_retries_without_losing_job
    enqueue
    @api.error = ApiError.new(429, 'Too Many Requests', 90)
    @feed.process_next
    assert_equal 1, @feed.stats['queued']
    @now += 89
    refute @feed.process_next
    @now += 1
    @api.error = nil
    assert @feed.process_next
    assert_equal 1, @feed.stats['sent']
  end

  def test_rate_limit_also_pauses_other_posts
    enqueue
    enqueue('2')
    @api.error = ApiError.new(429, '', 90)
    @feed.process_next
    @api.error = nil
    @now += 89
    refute @feed.process_next
    assert_equal 2, @feed.stats['queued']
    @now += 1
    assert @feed.process_next
  end

  def test_retries_are_bounded
    enqueue
    @api.error = ApiError.new(500)
    8.times do
      @feed.process_next
      @now += 10_000
    end
    assert_equal 1, @feed.stats['failed']
    refute @feed.process_next
  end

  def test_explicit_server_error_retries
    enqueue
    @api.error = ApiError.new(502)
    @feed.process_next
    assert_equal 1, @feed.stats['queued']
  end

  def test_network_timeout_is_uncertain_and_not_retried
    enqueue
    @api.error = IOError.new('connection lost after sending')
    @feed.process_next
    assert_equal 1, @feed.stats['uncertain']
    @feed.retry_failed
    @now += 9999
    refute @feed.process_next
    assert_equal 1, new_feed.stats['uncertain']
  end

  def test_permanent_failure_can_be_retried_explicitly
    enqueue
    @api.error = ApiError.new(403)
    @feed.process_next
    assert_equal 1, @feed.stats['failed']
    @feed.retry_failed
    @api.error = nil
    @feed.process_next
    assert_equal 1, @feed.stats['sent']
  end

  def test_interrupted_send_is_not_replayed_after_restart
    enqueue
    @api.before_send = -> { assert_equal 1, new_feed.stats['uncertain'] }
    @feed.process_next
  end

  def test_ban_blocks_pending_and_future_but_does_not_delete_posts
    enqueue
    @feed.process_next
    enqueue('2')
    @feed.moderate('ban', 1, actor_id: 42)
    assert_equal 1, @feed.stats['blocked']
    assert_equal 1, @feed.stats['sent']
    assert_equal :banned, enqueue('3')
    refute @feed.process_next
    @feed = new_feed
    assert_equal :banned, enqueue('4')
    @feed.moderate('unban', 1, actor_id: 42)
    assert_equal :queued, enqueue('5')
    assert_equal 1, @feed.stats['blocked']
  end

  def test_ban_serializes_with_inflight_delivery
    enqueue
    @feed.process_next
    enqueue('2')
    entered, release = Queue.new, Queue.new
    @api.before_send = -> { entered << true; release.pop }
    sender = Thread.new { @feed.process_next }
    entered.pop
    blocker = Thread.new { @feed.moderate('ban', 1, actor_id: 42) }
    release << true
    sender.join
    blocker.join
    assert_equal :banned, enqueue('3')
  end

  def test_purge_is_scoped_and_requires_actor_bound_confirmation
    enqueue
    @feed.process_next
    enqueue('2', 'user:20')
    @feed.process_next
    assert_raises(VideoFeedError) { @feed.moderate('purge', 1, actor_id: 42) }
    @feed.moderate('ban', 1, actor_id: 42)
    response = @feed.moderate('purge', 1, actor_id: 42)
    token = response[/\/feed_confirm (\h+)/, 1]
    assert_equal 2, @feed.stats['sent']
    assert_raises(VideoFeedError) { @feed.confirm_purge(token, actor_id: 43) }
    @feed.confirm_purge(token, actor_id: 42)
    assert_raises(VideoFeedError) { @feed.confirm_purge(token, actor_id: 42) }
    @feed.process_next
    assert_equal [:delete_message, { chat_id: -10042, message_id: 1 }], @api.calls.last
    assert_equal 1, @feed.stats['deleted']
    assert_equal 1, @feed.stats['sent']
    assert_equal :duplicate, enqueue('1', 'user:30')
  end

  def test_confirmation_expires
    enqueue
    @feed.process_next
    @feed.moderate('ban', 1, actor_id: 42)
    token = @feed.moderate('purge', 1, actor_id: 42)[/\/feed_confirm (\h+)/, 1]
    @now += 301
    assert_raises(VideoFeedError) { @feed.confirm_purge(token, actor_id: 42) }
  end

  def test_older_posts_are_not_promised_as_deletable
    enqueue
    @feed.process_next
    @feed.moderate('ban', 1, actor_id: 42)
    @now += 48 * 3600
    error = assert_raises(VideoFeedError) { @feed.moderate('purge', 1, actor_id: 42) }
    assert_includes error.message, 'вручную'
  end

  def test_already_deleted_post_is_treated_as_success
    enqueue
    @feed.process_next
    @feed.moderate('ban', 1, actor_id: 42)
    token = @feed.moderate('purge', 1, actor_id: 42)[/\/feed_confirm (\h+)/, 1]
    @feed.confirm_purge(token, actor_id: 42)
    @api.error = ApiError.new(400, 'Bad Request: message to delete not found')
    @feed.process_next
    assert_equal 1, @feed.stats['deleted']
  end

  def test_moderation_auth_is_verified_on_every_command
    enqueue
    @feed.process_next
    command('/feed_ban https://t.me/pobo4ka_ink/1')
    assert_equal 1, @feed.stats['banned']
    @api.member = OpenStruct.new(status: 'member')
    command('/feed_unban https://t.me/pobo4ka_ink/1')
    assert_equal 1, @feed.stats['banned']
    assert_includes last_reply, 'только владельцу'
    @api.member = OpenStruct.new(status: 'administrator', can_delete_messages: false)
    command('/feed')
    assert_includes last_reply, 'только владельцу'
    @api.member = OpenStruct.new(status: 'administrator', can_delete_messages: true)
    command('/feed')
    assert_includes last_reply, 'заблокировано отправителей: 1'
  end

  def test_other_channels_or_unknown_posts_cannot_be_moderated
    command('/feed_ban https://t.me/other/1')
    assert_includes last_reply, 'Укажи ссылку'
    command('/feed_ban https://t.me/pobo4ka_ink/99')
    assert_includes last_reply, 'Не нашёл'
    assert_equal 0, @feed.stats['banned']
  end

  def test_group_commands_do_not_reveal_private_moderation_data
    assert command('/feed', chat: OpenStruct.new(id: -20, type: 'group'))
    assert_empty @api.calls
    refute command('/help')
  end

  def test_bot_automatic_forward_protected_and_feed_sources_excluded
    assert_equal 'user:10', video_feed_submitter(build_message(''))
    assert_nil video_feed_submitter(build_message('', from: OpenStruct.new(id: 10, is_bot: true)))
    assert_nil video_feed_submitter(build_message('', has_protected_content: true))
    assert_nil video_feed_submitter(build_message('', is_automatic_forward: true))
    assert_nil video_feed_submitter(build_message('', chat: OpenStruct.new(id: -10042, type: 'channel')))
    assert_nil video_feed_submitter(build_message('', sender_chat: OpenStruct.new(id: -5)))
  end

  def test_fingerprints_normalize_tracking_and_host_aliases
    file = File.join(@directory, 'video.mp4')
    File.write(file, 'not a real video')
    first = video_feed_keys('https://x.com/one/status/123?s=52', file)
    second = video_feed_keys('https://twitter.com/other/status/123', file)
    assert_equal first, second
    assert_equal video_feed_keys('https://www.instagram.com/reel/abc/?igsh=x', file), video_feed_keys('https://instagram.com/p/abc/', file)
    assert_equal video_feed_keys('https://youtube.com/shorts/ABC?si=x', file), video_feed_keys('https://m.youtube.com/shorts/ABC', file)
    refute_includes first.join, 'one'
  end

  def test_album_mapping_and_missing_video
    messages = [OpenStruct.new(video: OpenStruct.new(file_id: 'v1', file_unique_id: 'u1')),
                OpenStruct.new(video: nil), OpenStruct.new(video: OpenStruct.new(file_id: 'v3', file_unique_id: 'u3'))]
    enqueue_video_feed(messages, submitter: 'user:10', keys: [%w[key1], %w[key2], %w[key3]])
    assert_equal 2, @feed.stats['queued']
    @feed.process_next
    @feed.process_next
    assert_equal %w[v1 v3], @api.calls.map { |_, args| args[:video] }
  end

  def test_corrupt_state_fails_closed_and_is_not_overwritten
    File.write(@file, '{broken')
    assert_raises(JSON::ParserError) { new_feed }
    assert_equal '{broken', File.read(@file)
  end

  def test_destination_change_fails_closed
    assert_raises(VideoFeedError) { VideoFeed.new(path: @file, api: @api, channel_id: -999, username: 'another') }
  end

  def test_private_chat_needs_consent_but_groups_work_by_default
    assert_equal :private, enqueue('1', 'user:10', private_chat: true)
    assert_equal :queued, enqueue('2')
    @feed.set_preference('user:10', enabled: true)
    assert_equal :queued, enqueue('3', 'user:10', private_chat: true)
    assert_equal 'on', new_feed.preference('user:10')
  end

  def test_opt_out_cancels_queue_and_blocks_later_download_results
    enqueue
    assert_equal 1, @feed.set_preference('user:10', enabled: false)
    assert_equal :private, enqueue('2')
    assert_equal :private, enqueue('3', 'user:10', private_chat: true)
    refute @feed.process_next
    assert_equal 'off', new_feed.preference('user:10')
    @feed.retry_failed
    refute @feed.process_next
    @feed.set_preference('user:10', enabled: true)
    refute @feed.process_next
    assert_equal :queued, enqueue('4')
  end

  def test_unpublished_cancelled_video_does_not_block_another_submitter
    enqueue
    @feed.set_preference('user:10', enabled: false)
    assert_equal :queued, enqueue('1', 'user:20')
  end

  def test_opt_out_keeps_published_post
    enqueue
    @feed.process_next
    @feed.set_preference('user:10', enabled: false)
    assert_equal 1, @feed.stats['sent']
    assert_empty @api.calls.select { |name, _| name == :delete_message }
  end

  def test_privacy_keyboard_and_callback_belong_to_private_sender
    msg = build_message('/privacy')
    assert handle_video_feed_privacy_command(@bot, msg, '/privacy')
    keyboard = JSON.parse(@api.calls.last[1][:reply_markup])
    assert_equal %w[feed_privacy:off feed_privacy:on], keyboard['inline_keyboard'].flatten.map { |item| item['callback_data'] }
    enqueue
    callback = OpenStruct.new(id: 'cb1', data: 'feed_privacy:off', from: msg.from, message: msg)
    assert handle_video_feed_privacy_callback(@bot, callback)
    assert_equal 'off', @feed.preference('user:10')
    assert_equal 1, @feed.stats['opted_out']
    callback.data = 'feed_privacy:on'
    callback.from = OpenStruct.new(id: 11, is_bot: false)
    assert handle_video_feed_privacy_callback(@bot, callback)
    assert_equal 'off', @feed.preference('user:10')
    assert_nil @feed.preference('user:11')
    callback.from = msg.from
    assert handle_video_feed_privacy_callback(@bot, callback)
    assert_equal 'on', @feed.preference('user:10')
  end

  def test_privacy_changes_do_not_override_moderator_ban
    enqueue
    @feed.process_next
    @feed.moderate('ban', 1, actor_id: 42)
    @feed.set_preference('user:10', enabled: true)
    assert_equal :banned, enqueue('2', 'user:10', private_chat: true)
  end

  def test_failed_persistence_does_not_change_effective_privacy_or_queue
    enqueue
    # A directory at the target path makes atomic rename fail reliably, even as root.
    File.delete(@file)
    Dir.mkdir(@file)
    assert_raises(SystemCallError) { @feed.set_preference('user:10', enabled: false) }
    assert_nil @feed.preference('user:10')
    assert_equal 1, @feed.stats['queued']
  end

  def test_download_started_before_opt_out_cannot_publish_after_reenable
    version = @feed.privacy_version('user:10')
    @feed.set_preference('user:10', enabled: false)
    @feed.set_preference('user:10', enabled: true)
    assert_equal :private, enqueue('old', 'user:10', privacy_version: version)
    assert_equal :queued, enqueue('new', 'user:10', privacy_version: @feed.privacy_version('user:10'))
    assert_equal @feed.privacy_version('user:10'), new_feed.privacy_version('user:10')
  end

  def first_submission
    prepare_video_feed_submission(@bot, build_message('https://x.com/test/status/1'))
  end

  def complete_download(context, id = 'first')
    @feed.enqueue(file_id: "file-#{id}", keys: ["key-#{id}"], **context)
  end

  def consent(context)
    @feed.set_preference(context[:submitter], enabled: true, consent_request: context[:consent_request])
  end

  def test_first_video_waits_until_the_associated_consent_is_received
    context = first_submission
    assert_equal :awaiting_consent, complete_download(context)
    refute @feed.process_next
    keyboard = JSON.parse(@api.calls.last[1][:reply_markup])
    callback_data = keyboard['inline_keyboard'][1][0]['callback_data']
    assert_equal "feed_privacy:on:#{context[:consent_request]}", callback_data
    assert_operator callback_data.bytesize, :<=, 64
    msg = build_message('')
    callback = OpenStruct.new(id: 'first', data: callback_data, message: msg, from: msg.from)
    assert handle_video_feed_privacy_callback(@bot, callback)
    assert_equal 1, @feed.stats['queued']
    assert @feed.process_next
    assert_equal 1, @feed.stats['sent']
    assert handle_video_feed_privacy_callback(@bot, callback)
    refute @feed.process_next
  end

  def test_consent_before_download_finishes_includes_that_video
    context = first_submission
    consent(context)
    assert_equal :queued, complete_download(context)
    @feed.process_next
    assert_equal 1, @feed.stats['sent']
  end

  def test_waiting_video_and_consent_request_survive_restart
    context = first_submission
    complete_download(context)
    @feed = new_feed
    refute @feed.process_next
    consent(context)
    @feed.process_next
    assert_equal 1, @feed.stats['sent']
  end

  def test_approved_request_survives_restart_before_download_completes
    context = first_submission
    consent(context)
    @feed = new_feed
    assert_equal :queued, complete_download(context)
  end

  def test_opt_out_revokes_waiting_and_inflight_consent_requests
    waiting = first_submission
    downloading = first_submission
    complete_download(waiting)
    assert_equal 1, @feed.set_preference('user:10', enabled: false)
    @feed.set_preference('user:10', enabled: true)
    assert_raises(VideoFeedError) { consent(waiting) }
    assert_raises(VideoFeedError) { consent(downloading) }
    assert_equal :private, complete_download(downloading, 'later')
    refute @feed.process_next
  end

  def test_opt_out_after_early_consent_revokes_inflight_download
    context = first_submission
    consent(context)
    @feed.set_preference('user:10', enabled: false)
    @feed.set_preference('user:10', enabled: true)
    assert_equal :private, complete_download(context)
  end

  def test_only_the_selected_message_is_released_not_other_private_history
    first, second = first_submission, first_submission
    complete_download(first, 'one')
    complete_download(second, 'two')
    consent(second)
    assert_equal 1, @feed.stats['queued']
    assert_equal 1, @feed.stats['opted_out']
    @feed.process_next
    assert_equal 'file-two', @api.calls.last[1][:video]
    refute @feed.process_next
  end

  def test_all_videos_in_consented_message_are_released_without_duplicates
    context = first_submission
    assert_equal :awaiting_consent, complete_download(context, 'one')
    assert_equal :awaiting_consent, complete_download(context, 'two')
    assert_equal :duplicate, complete_download(context, 'two')
    consent(context)
    consent(context)
    assert_equal 2, @feed.stats['queued']
  end

  def test_waiting_private_video_does_not_reserve_global_deduplication
    context = first_submission
    complete_download(context)
    assert_equal :queued, enqueue('first', 'user:20')
    @feed.process_next
    consent(context)
    assert_equal 1, @feed.stats['duplicate']
    refute @feed.process_next
  end

  def test_expired_request_cannot_enable_publication_or_retain_private_video
    context = first_submission
    complete_download(context)
    @now += 24 * 3600
    refute @feed.process_next
    assert_nil @feed.stats['awaiting_consent']
    assert_raises(VideoFeedError) { consent(context) }
    assert_nil @feed.preference('user:10')
    assert_equal :private, complete_download(context)
  end

  def test_consent_token_is_bound_to_its_submitter
    context = first_submission
    assert_raises(VideoFeedError) { @feed.set_preference('user:20', enabled: true, consent_request: context[:consent_request]) }
    assert_nil @feed.preference('user:20')
    assert_nil @feed.preference('user:10')
    assert_equal :private, complete_download(context.merge(submitter: 'user:20'))
  end

  def test_generic_settings_and_old_buttons_do_not_backfill_private_videos
    context = first_submission
    complete_download(context)
    @feed.set_preference('user:10', enabled: true)
    refute @feed.process_next
    assert_equal 1, @feed.stats['opted_out']
  end

  def test_consent_and_download_completion_can_race_safely
    context = first_submission
    threads = [Thread.new { consent(context) }, Thread.new { complete_download(context) }]
    threads.each(&:value)
    assert_equal 1, @feed.stats['queued']
    @feed.process_next
    assert_equal 1, @feed.stats['sent']
  end

  def test_disabled_users_never_get_held_submissions
    @feed.set_preference('user:10', enabled: false)
    assert_nil first_submission
    assert_empty @api.calls
  end

  def test_banning_also_revokes_unapproved_submissions
    enqueue('previous')
    @feed.process_next
    context = first_submission
    complete_download(context)
    @feed.moderate('ban', 1, actor_id: 42)
    @feed.moderate('unban', 1, actor_id: 42)
    assert_raises(VideoFeedError) { consent(context) }
    refute @feed.process_next
  end
end
