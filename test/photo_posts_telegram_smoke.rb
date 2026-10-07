# frozen_string_literal: true

# Exercise the installed telegram-bot-ruby types and HTTP serialization offline.
# Faraday's test adapter cannot send requests to Telegram or any external service.
ENV['TELEGRAM_BOT_TOKEN'] = '000:photo-tests'
require_relative '../lib/telegram_instwitter_bot/config'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/media_jobs'
require_relative '../lib/telegram_instwitter_bot/photo_posts'
require_relative '../lib/telegram_instwitter_bot/onboarding'

def check(condition, description)
  raise description unless condition
end

def typed_message(id, **attributes)
  Telegram::Bot::Types::Message.new({
    message_id: id, date: 1,
    chat: { id: 10, type: 'private' },
    from: { id: 20, is_bot: false, first_name: 'Photo test' }
  }.merge(attributes.compact))
end

requests = []
stubs = Faraday::Adapter::Test::Stubs.new do |stub|
  stub.post('/bot000:photo-tests/sendMessage') do |env|
    params = URI.decode_www_form(env.body).to_h
    [200, {}, JSON.generate(ok: true, result: typed_message(10, text: params['text']).to_h)]
  end
  stub.post('/bot000:photo-tests/sendMediaGroup') do |env|
    params = URI.decode_www_form(env.body).to_h
    media = JSON.parse(params.fetch('media'))
    media.each { |item| Telegram::Bot::Types::InputMediaPhoto.new(item.transform_keys(&:to_sym)) }
    requests << [:album, media]
    [200, {}, JSON.generate(ok: true, result: media.each_index.map { |i| typed_message(20 + i).to_h })]
  end
  stub.post('/bot000:photo-tests/sendPhoto') do |env|
    params = URI.decode_www_form(env.body).to_h
    requests << [:photo, params]
    [200, {}, JSON.generate(ok: true, result: typed_message(30).to_h)]
  end
end
connection = Faraday.new do |builder|
  builder.request :multipart
  builder.request :url_encoded
  builder.adapter :test, stubs
end
api = Telegram::Bot::Api.new('000:photo-tests')
api.instance_variable_set(:@connection, connection)
bot = Struct.new(:api).new(api)
queue = SizedQueue.new(4)

Dir.mktmpdir('photo-telegram-smoke-') do |dir|
  store = PhotoPostStore.new(File.join(dir, 'photos.json'))
  [1, 2].each do |id|
    photo = typed_message(id,
      photo: [{ file_id: "photo-#{id}", file_unique_id: "unique-#{id}", width: 640, height: 480 }],
      caption: id == 1 ? 'Bold' : nil,
      caption_entities: id == 1 ? [{ type: 'bold', offset: 0, length: 4 }] : nil)
    check(handle_photo_post_message(bot, queue, photo, '', addressed: true, bot_username: 'test_bot', store: store), 'Photo routing failed')
  end
  handle_photo_post_message(bot, queue, typed_message(3), 'собери пост', addressed: true, bot_username: 'test_bot', store: store)
  process_media_job(bot, queue.pop(true))
  check(requests.size == 1 && requests[0][0] == :album, 'Expected one album request')
  check(requests[0][1].map { |p| p['media'] } == %w[photo-1 photo-2], 'Photo order mismatch')
  check(requests[0][1][0]['caption_entities'][0]['type'] == 'bold', 'Caption formatting lost')

  handle_photo_post_message(bot, queue, typed_message(4), 'собери пост из последних 1 фото', addressed: true, bot_username: 'test_bot', store: store)
  process_media_job(bot, queue.pop(true))
  check(requests.size == 2 && requests[1][0] == :photo, 'Expected one standalone photo request')
  check(requests[1][1]['photo'] == 'photo-2', 'Wrong recent photo')
  # Ordinary group photos arrive without a mention; the command is addressed.
  group_photo = typed_message(5, date: 7200, chat: { id: -10, type: 'group', title: 'Test' },
    photo: [{ file_id: 'group-photo', file_unique_id: 'group-unique', width: 640, height: 480 }])
  check(handle_photo_post_message(bot, queue, group_photo, '', addressed: false, bot_username: 'test_bot', store: store), 'Unmentioned group photo was ignored')
  command = typed_message(6, date: 7300, chat: { id: -10, type: 'group', title: 'Test' })
  handle_photo_post_message(bot, queue, command, 'собери пост за 2 часа', addressed: true, bot_username: 'test_bot', store: store)
  process_media_job(bot, queue.pop(true))
  check(requests.size == 3 && requests[2][1]['photo'] == 'group-photo', 'Group time selection failed')
  check(media_source_for_link('https://t.me/example/123').nil?, 'Telegram link regression')
  %w[ru en].each do |language|
    check(onboarding_instructions(language, 'test_bot').length <= 4096, 'Help exceeds Telegram message limit')
  end
end
stubs.verify_stubbed_calls
puts 'PASS: real Telegram message types, album/single-photo HTTP serialization, captions, routing, help size; no network requests'
