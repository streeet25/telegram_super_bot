# frozen_string_literal: true

ENV['TELEGRAM_BOT_TOKEN'] = '000:routing-tests'
require_relative '../lib/telegram_instwitter_bot/config'
require_relative '../lib/telegram_instwitter_bot/update_routing'
require_relative '../lib/telegram_instwitter_bot/media_jobs'

def check(condition, description); raise description unless condition; end

chat = { id: -10, type: 'supergroup', title: 'Routing fixture' }
sender = { id: 20, is_bot: false, first_name: 'Fixture' }
message = { message_id: 100, date: 1, chat: chat, from: sender,
            text: 'https://www.instagram.com/reel/fixture/' }
reaction = { chat: chat, message_id: 100, date: 2, user: sender,
             old_reaction: [], new_reaction: [{ type: 'emoji', emoji: '👍' }] }
callback = { id: 'callback-fixture', from: sender, chat_instance: 'fixture',
             message: message.merge(edit_date: 2), data: 'feed_item:status:fixture' }
payloads = [
  { message: message },
  { edited_message: message.merge(edit_date: 2) },
  { message_reaction: reaction },
  { message_reaction: reaction.merge(old_reaction: reaction[:new_reaction], new_reaction: []) },
  { message_reaction_count: { chat: chat, message_id: 100, date: 3,
                            reactions: [{ type: { type: 'emoji', emoji: '👍' }, total_count: 1 }] } },
  # Metadata updates may not expose a changed field, including edit_date.
  { edited_message: message },
  { edited_message: message.merge(text: 'https://x.com/fixture/status/123', edit_date: 4) },
  { edited_channel_post: message },
  { edited_business_message: message },
  { callback_query: callback },
  # Preserve actual new channel/business messages and photo collection.
  { channel_post: message.merge(message_id: 101, chat: { id: -20, type: 'channel', title: 'Fixture' }) },
  { business_message: message.merge(message_id: 102, business_connection_id: 'fixture') },
  { message: message.reject { |key, _| key == :text }.merge(message_id: 103,
    photo: [{ file_id: 'photo', file_unique_id: 'photo-unique', width: 640, height: 480 }]) },
  # A deliberately re-sent link is a new request, not a reaction duplicate.
  { message: message.merge(message_id: 104) },
  # Unsupported update variants should still advance the offset safely.
  {}
]
updates = payloads.each_with_index.map { |payload, index| payload.merge(update_id: 500 + index) }
# Reproduce the old boundary: the stock listener delivers an edited link as an
# ordinary Message, which bot.rb would download again.
legacy = Telegram::Bot::Client.new('000:routing-tests')
old_payload = legacy.handle_update(Telegram::Bot::Types::Update.new(update_id: 499, edited_message: message))
check(old_payload.is_a?(Telegram::Bot::Types::Message) && extract_video_link_items(old_payload.text).size == 1,
      'Fixture does not reproduce the old edited-message download path')
requests = []
stubs = Faraday::Adapter::Test::Stubs.new do |stub|
  stub.post('/bot000:routing-tests/getUpdates') do |env|
    params = URI.decode_www_form(env.body).to_h
    requests << params
    allowed = JSON.parse(params.fetch('allowed_updates'))
    check(allowed == %w[message channel_post business_message callback_query], 'Wrong update subscription')
    if requests.size == 1
      [200, {}, JSON.generate(ok: true, result: updates)]
    else
      check(params['offset'].to_i == 515, 'Ignored updates were not acknowledged')
      [200, {}, JSON.generate(ok: true, result: [])]
    end
  end
end
client = TelegramUpdateClient.new('000:routing-tests', timeout: 1)
client.api.instance_variable_set(:@connection, Faraday.new do |builder|
  builder.request :multipart
  builder.request :url_encoded
  builder.adapter :test, stubs
end)

delivered = []
client.fetch_updates { |item| delivered << item if item }
client.fetch_updates { |_| raise 'Unexpected update in empty second batch' }
messages = delivered.grep(Telegram::Bot::Types::Message)
check(messages.map(&:message_id) == [100, 101, 102, 103, 104], 'An edit was re-routed or a new message was lost')
check(delivered.grep(Telegram::Bot::Types::CallbackQuery).map(&:id) == ['callback-fixture'], 'Buttons stopped working')
link_jobs = messages.flat_map { |item| extract_video_link_items(item.text.to_s) }
check(link_jobs.size == 4, 'Reaction/edit triggered another media download')
check(messages.count { |item| item.message_id == 100 } == 1, 'Original message was handled twice')
check(messages.find { |item| item.message_id == 103 }.photo.size == 1, 'Photo input was lost')
check(client.options[:offset] == 515, 'Offset did not advance past the last ignored update')
check(client.options[:timeout] == 1, 'Existing client options were changed')

# A fresh process must also ignore an old edited message, without needing an
# in-memory cache or resetting pending updates (and without swallowing callbacks).
restarted = TelegramUpdateClient.new('000:routing-tests')
check(restarted.handle_update(Telegram::Bot::Types::Update.new(update_id: 900, edited_message: message)).nil?,
      'Old message replayed after restart')
check(restarted.options[:offset] == 901, 'Restarted client did not acknowledge an edit')
check(restarted.handle_update(Telegram::Bot::Types::Update.new(update_id: 901, callback_query: callback)).is_a?(Telegram::Bot::Types::CallbackQuery),
      'Callback with edited nested message was suppressed')
stubs.verify_stubbed_calls
puts 'PASS: real getUpdates serialization, reaction/edit suppression (including pending updates/restart), new messages/photos/channels/business and callbacks preserved; no network'
