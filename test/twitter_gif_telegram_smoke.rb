# frozen_string_literal: true

# Real telegram-bot-ruby Message/Animation types and HTTP serialization, offline.
ENV['TELEGRAM_BOT_TOKEN'] = '000:gif-tests'
require_relative '../lib/telegram_instwitter_bot/config'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/ytdlp'
require_relative '../lib/telegram_instwitter_bot/media_jobs'
require_relative '../lib/telegram_instwitter_bot/video_feed'

def check(condition, description)
  raise description unless condition
end

def typed_gif(id, chat_id: 10)
  Telegram::Bot::Types::Message.new(message_id: id, date: 1,
    chat: { id: chat_id, type: chat_id == 10 ? 'private' : 'channel', title: 'Test' },
    from: { id: 10, is_bot: false, first_name: 'Test' },
    animation: { file_id: 'gif-file', file_unique_id: 'gif-unique', width: 64, height: 64, duration: 1 },
    document: { file_id: 'gif-file', file_unique_id: 'gif-unique', mime_type: 'video/mp4' })
end

def download_twitter_video(_link)
  yield('videomorph_media_type' => 'animation') if block_given?
  path = File.join(Dir.mktmpdir('tw_video_gif_smoke_'), 'gif.mp4')
  FileUtils.cp(@gif_fixture, path)
  @downloaded_path = path
  path
end

requests = []
stubs = Faraday::Adapter::Test::Stubs.new do |stub|
  stub.post('/bot000:gif-tests/sendAnimation') do |env|
    if env.request_headers['Content-Type'].to_s.start_with?('multipart/form-data')
      body = env.body.respond_to?(:read) ? env.body.read : env.body.to_s
      check(body.include?('name="animation"'), 'Animation multipart field missing')
      check(body.include?('filename="gif.mp4"'), 'Original silent MP4 is not uploaded as animation')
      check(!body.include?('supports_streaming'), 'sendVideo-only parameter leaked into animation upload')
      requests << [:upload, {}]
      [200, {}, JSON.generate(ok: true, result: typed_gif(301).to_h)]
    else
      params = URI.decode_www_form(env.body).to_h
      check(params == { 'chat_id' => '-10042', 'animation' => 'gif-file' }, 'Channel send has wrong file type or attribution')
      requests << [:publish, params]
      [200, {}, JSON.generate(ok: true, result: typed_gif(401, chat_id: -10042).to_h)]
    end
  end
  stub.post('/bot000:gif-tests/editMessageCaption') do |env|
    params = URI.decode_www_form(env.body).to_h
    check(params['caption'] == 'GIF из Twitter', 'Publication status leaked into GIF caption')
    Telegram::Bot::Types::InlineKeyboardMarkup.new(JSON.parse(params.fetch('reply_markup'), symbolize_names: true))
    requests << [:edit, params]
    [200, {}, JSON.generate(ok: true, result: typed_gif(301).to_h)]
  end
  stub.post('/bot000:gif-tests/answerCallbackQuery') { [200, {}, JSON.generate(ok: true, result: true)] }
end
api = Telegram::Bot::Api.new('000:gif-tests')
api.instance_variable_set(:@connection, Faraday.new do |builder|
  builder.request :multipart
  builder.request :url_encoded
  builder.adapter :test, stubs
end)
bot = Struct.new(:api).new(api)

Dir.mktmpdir('twitter-gif-smoke-') do |dir|
  Dir.chdir(dir) do
    @gif_fixture = File.join(dir, 'fixture.mp4')
    _output, status = Open3.capture2e('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'color=c=blue:s=64x64:r=10', '-t', '1', '-an', '-c:v', 'libx264',
      '-pix_fmt', 'yuv420p', @gif_fixture)
    check(status.success?, 'Could not generate silent H.264 fixture')
    now = 1800000000
    path = File.join(dir, 'feed.json')
    @video_feed = VideoFeed.new(path: path, api: api, channel_id: -10042, username: 'pobo4ka_ink', clock: -> { now })
    @video_feed.set_preference('user:10', enabled: true)
    items = prepare_video_feed_items(bot, typed_gif(1), [{ source: :twitter, link: 'https://x.com/test/status/123' }])
    process_video_link_batch(bot, 10, items)
    check(requests.count { |name, _| name == :upload } == 1, 'GIF upload failed')
    check(!File.exist?(@downloaded_path), 'Downloaded GIF was not cleaned up')
    check(!File.exist?(MEDIA_HISTORY_FILE), 'Animation ID polluted video album history')
    edit = requests.find { |name, _| name == :edit }[1]
    button = JSON.parse(edit['reply_markup'])['inline_keyboard'][0][0]
    check(button['text'] == 'Опубликовать в Побочку', 'Wrong manual GIF button')
    now += 3600
    @video_feed = VideoFeed.new(path: path, api: api, channel_id: -10042, username: 'pobo4ka_ink', clock: -> { now })
    check(!@video_feed.process_next, 'Default GIF auto-published after restart')
    callback = Telegram::Bot::Types::CallbackQuery.new(id: 'gif-click', chat_instance: 'test',
      from: typed_gif(301).from, message: typed_gif(301), data: button['callback_data'])
    check(handle_video_feed_control_callback(bot, callback), 'Animation callback was not handled')
    check(@video_feed.process_next, 'Explicit GIF publication was not queued')
    check(requests.count { |name, _| name == :publish } == 1, 'Animation file ID did not publish through sendAnimation')
    handle_video_feed_control_callback(bot, callback)
    check(!@video_feed.process_next, 'Repeated button click republished GIF')
    check(@video_feed.preference('user:10') == 'on', 'Per-GIF action changed general preference')
  end
end
stubs.verify_stubbed_calls
puts 'PASS: actual GIF upload, native Animation callback, manual-only default across restart, anonymous sendAnimation file-ID publication; no network'
