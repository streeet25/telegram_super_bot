# frozen_string_literal: true

ENV['TELEGRAM_BOT_TOKEN'] = '000:feed-tests'
require_relative '../lib/telegram_instwitter_bot/config'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/media_jobs'
require_relative '../lib/telegram_instwitter_bot/video_feed'
require_relative '../lib/telegram_instwitter_bot/onboarding'
require_relative 'support/video_fingerprint_fixture'

def check(condition, description)
  raise description unless condition
end

def typed_message(id, **attributes)
  Telegram::Bot::Types::Message.new({
    message_id: id, date: Time.now.to_i,
    chat: { id: 10, type: 'private' },
    from: { id: 10, is_bot: false, first_name: 'Test' }
  }.merge(attributes))
end

# Simulate only the external downloader/upload endpoint; run the application's
# real batch routing, album assembly, fingerprinting and enqueue integration.
def download_twitter_video(link)
  return nil if link.end_with?('/missing')

  file = File.join(Dir.mktmpdir('tw_video_smoke_'), 'video.mp4')
  File.write(file, link)
  file
end

def video_upload_metadata(_path)
  { width: 640, height: 480, duration: 2 }
end

# Decoder fixtures run separately against real ffmpeg. Here verify descriptors
# survive the real delivery/album/consent path before temporary files disappear.
VideoFingerprint.extend(VideoFingerprintFixture)
VideoFingerprint.define_singleton_method(:extract) do |path, runner:, timeout:|
  raise 'Fingerprinting after cleanup' unless File.file?(path)

  visual_fixture(Digest::SHA256.file(path).hexdigest[0, 8].to_i(16))
end

class UploadApi
  attr_accessor :fail_upload
  attr_reader :calls

  def initialize
    @calls = []
  end

  def send_video(**params)
    raise 'simulated upload failure' if fail_upload

    raise 'Expected actual multipart upload' unless params[:video].is_a?(Faraday::UploadIO)

    @calls << :single
    response(201)
  end

  def send_media_group(**params)
    raise 'simulated upload failure' if fail_upload

    media = JSON.parse(params.fetch(:media))
    media.each_with_index do |item, index|
      Telegram::Bot::Types::InputMediaVideo.new(item.transform_keys(&:to_sym))
      raise 'Expected attach:// reference' unless item['media'] == "attach://video_#{index}"
    end
    @calls << :album
    media.each_index.map { |index| response(202 + index) }
  end

  def send_message(**_params); end

  def response(id)
    Telegram::Bot::Types::Message.new(message_id: id, date: Time.now.to_i,
      chat: { id: 10, type: 'private' },
      video: { file_id: "upload#{id}", file_unique_id: "unique#{id}", width: 640, height: 480, duration: 2 })
  end
end

requests = []
fail_next = false
stubs = Faraday::Adapter::Test::Stubs.new do |stub|
  stub.post('/bot000:feed-tests/sendVideo') do |env|
    params = URI.decode_www_form(env.body).to_h
    requests << [:video, params]
    if fail_next
      fail_next = false
      [429, {}, JSON.generate(ok: false, error_code: 429, description: 'Too Many Requests', parameters: { retry_after: 1 })]
    else
      check(params.keys.sort == %w[chat_id supports_streaming video], 'Unexpected attribution/caption/forwarding parameters')
      [200, {}, JSON.generate(ok: true, result: typed_message(101, chat: { id: -10042, type: 'channel', title: 'Feed' },
        video: { file_id: params.fetch('video'), file_unique_id: 'unique1', width: 640, height: 480, duration: 2 }).to_h)]
    end
  end
  stub.post('/bot000:feed-tests/sendMessage') do |env|
    params = URI.decode_www_form(env.body).to_h
    requests << [:message, params]
    if params['reply_markup']
      Telegram::Bot::Types::InlineKeyboardMarkup.new(JSON.parse(params['reply_markup'], symbolize_names: true))
    end
    [200, {}, JSON.generate(ok: true, result: typed_message(102, text: params['text']).to_h)]
  end
  stub.post('/bot000:feed-tests/answerCallbackQuery') { [200, {}, JSON.generate(ok: true, result: true)] }
  stub.post('/bot000:feed-tests/getChatMember') do
    [200, {}, JSON.generate(ok: true, result: { status: 'creator', is_anonymous: false, user: { id: 10, is_bot: false, first_name: 'Owner' } })]
  end
  stub.post('/bot000:feed-tests/deleteMessage') do |env|
    requests << [:delete, URI.decode_www_form(env.body).to_h]
    [200, {}, JSON.generate(ok: true, result: true)]
  end
end
api = Telegram::Bot::Api.new('000:feed-tests')
api.instance_variable_set(:@connection, Faraday.new do |builder|
  builder.request :multipart
  builder.request :url_encoded
  builder.adapter :test, stubs
end)
bot = Struct.new(:api).new(api)

Dir.mktmpdir('feed-telegram-smoke-') do |dir|
  now = Time.now.to_i
  @video_feed = VideoFeed.new(path: File.join(dir, 'feed.json'), api: api, channel_id: -10042, username: 'pobo4ka_ink', clock: -> { now })
  sent = typed_message(100, caption: 'Private caption', video: { file_id: 'file1', file_unique_id: 'unique1', width: 640, height: 480, duration: 2 })
  context = prepare_video_feed_submission(bot, typed_message(99, text: 'https://x.com/test/status/100'))
  check(context[:consent_request], 'Initial private submission has no consent token')
  enqueue_video_feed(sent, **context, keys: [%w[sha:one]])
  check(!@video_feed.process_next, 'Private video leaked before consent')
  check(@video_feed.stats['awaiting_consent'] == 1, 'First video was discarded instead of waiting for consent')
  callback_data = JSON.parse(requests.last[1].fetch('reply_markup'))['inline_keyboard'][1][0]['callback_data']
  callback = Telegram::Bot::Types::CallbackQuery.new(id: 'c1', chat_instance: 'test', from: sent.from, message: sent, data: callback_data)
  check(handle_video_feed_privacy_callback(bot, callback), 'Consent callback not handled')
  check(@video_feed.stats['queued'] == 1, 'First video did not enter queue when consent was accepted')
  fail_next = true
  @video_feed.process_next
  check(@video_feed.stats['queued'] == 1, 'Actual Telegram ResponseError was not classified as retryable')
  now += 20
  @video_feed.process_next
  check(@video_feed.stats['sent'] == 1, 'File-ID video did not publish')
  duplicate = typed_message(110, video: { file_id: 'alternative-file-id', file_unique_id: 'unique1', width: 640, height: 480, duration: 2 })
  enqueue_video_feed(duplicate, submitter: 'user:30', keys: [%w[url:alternative sha:alternative]])
  check(@video_feed.stats['duplicates_skipped'] == 1, 'Actual Telegram unique ID did not suppress a different sender’s duplicate')
  check(@video_feed.enqueue(file_id: 'new-upload', keys: %w[url:alternative sha:changed], submitter: 'user:40') == :duplicate, 'Alternative URL was not remembered')
  check(!@video_feed.process_next, 'Duplicate triggered another channel send')
  handle_video_feed_command(bot, sent, '/feed_ban https://t.me/pobo4ka_ink/101')
  check(@video_feed.stats['banned'] == 1, 'Actual owner type failed moderation authorization')
  handle_video_feed_command(bot, sent, '/feed_purge https://t.me/pobo4ka_ink/101')
  token = requests.last[1]['text'][/\/feed_confirm (\h+)/, 1]
  check(token, 'Confirmation token missing')
  handle_video_feed_command(bot, sent, "/feed_confirm #{token}")
  @video_feed.process_next
  check(requests.last == [:delete, { 'chat_id' => '-10042', 'message_id' => '101' }], 'Delete target mismatch')
  uploads = UploadApi.new
  upload_bot = Struct.new(:api).new(uploads)
  Dir.chdir(dir) do
    context = { submitter: 'user:20', private_chat: false, privacy_version: 0 }
    process_media_job(upload_bot, type: :video_link_batch, chat_id: 10, feed_context: context,
      items: [{ link: 'https://x.com/test/status/21', source: :twitter }])
    check(@video_feed.stats['queued'] == 1 && uploads.calls == [:single], 'Single-download integration failed')
    process_media_job(upload_bot, type: :video_link_batch, chat_id: 10, feed_context: context,
      items: [22, 23].map { |id| { link: "https://x.com/test/status/#{id}", source: :twitter } })
    check(@video_feed.stats['queued'] == 3 && uploads.calls.last == :album, 'Album did not enqueue each successfully delivered video')
    jobs = JSON.parse(File.read(File.join(dir, 'feed.json')))['jobs'].select { |job| job['status'] == 'queued' }
    check(jobs.all? { |job| VideoFingerprint.valid?(job['visual']) }, 'Single/album visual descriptors were lost')
    uploads.fail_upload = true
    process_media_job(upload_bot, type: :video_link_batch, chat_id: 10, feed_context: context,
      items: [{ link: 'https://x.com/test/status/24', source: :twitter }])
    check(@video_feed.stats['queued'] == 3, 'Failed user delivery entered public feed')
    process_media_job(upload_bot, type: :video_link_batch, chat_id: 10, feed_context: context,
      items: [{ link: 'https://x.com/test/status/missing', source: :twitter }])
    check(@video_feed.stats['queued'] == 3, 'Missing download entered public feed')
  end
  %w[ru en].each { |language| check(onboarding_instructions(language, 'test_bot').length <= 4096, 'Help exceeds limit') }
end
stubs.verify_stubbed_calls
puts 'PASS: actual Telegram types, file-ID sendVideo, anonymous payload, privacy keyboard/callback, HTTP 429 retry, admin authorization and confirmed deletion; no network'
