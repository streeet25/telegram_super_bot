# frozen_string_literal: true

SUPPORTED_ONBOARDING_LANGUAGES = %w[ru en].freeze
DEFAULT_ONBOARDING_LANGUAGE = 'ru'
LANGUAGE_CALLBACK_PREFIX = 'language:'

def load_user_languages
  if File.exist?(USER_LANGUAGE_FILE)
    JSON.parse(File.read(USER_LANGUAGE_FILE))
  else
    {}
  end
end

def save_user_languages(languages)
  File.write(USER_LANGUAGE_FILE, JSON.pretty_generate(languages))
end

def get_user_language(user_id)
  language = load_user_languages[user_id.to_s]
  SUPPORTED_ONBOARDING_LANGUAGES.include?(language) ? language : DEFAULT_ONBOARDING_LANGUAGE
end

def set_user_language(user_id, language)
  return unless user_id && SUPPORTED_ONBOARDING_LANGUAGES.include?(language)

  languages = load_user_languages
  languages[user_id.to_s] = language
  save_user_languages(languages)
end

def private_chat?(message)
  message.respond_to?(:chat) && message.chat&.type == 'private'
end

def bot_command?(text, command_names, bot_username:, private_chat:)
  command_pattern = command_names.map { |name| Regexp.escape(name) }.join('|')
  bot_suffix = bot_username ? "@#{Regexp.escape(bot_username)}" : "@\\w+"
  pattern = if private_chat
              %r{\A/(?:#{command_pattern})(?:#{bot_suffix})?(?:\s|$)}i
            else
              %r{\A/(?:#{command_pattern})#{bot_suffix}(?:\s|$)}i
            end

  text.to_s.strip.match?(pattern)
end

def language_selection_markup
  keyboard = [[
    Telegram::Bot::Types::InlineKeyboardButton.new(text: 'RU', callback_data: "#{LANGUAGE_CALLBACK_PREFIX}ru"),
    Telegram::Bot::Types::InlineKeyboardButton.new(text: 'EN', callback_data: "#{LANGUAGE_CALLBACK_PREFIX}en")
  ]]

  Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
end

def send_language_selection(bot, chat_id)
  bot.api.send_message(
    chat_id: chat_id,
    text: "Выберите язык / Choose a language:",
    reply_markup: language_selection_markup
  )
end

def handle_language_callback(bot, callback, bot_username)
  language = callback.data.to_s.delete_prefix(LANGUAGE_CALLBACK_PREFIX)
  return false unless SUPPORTED_ONBOARDING_LANGUAGES.include?(language)

  set_user_language(callback.from&.id, language)
  bot.api.answer_callback_query(
    callback_query_id: callback.id,
    text: language == 'ru' ? 'Язык выбран' : 'Language selected'
  )

  chat_id = callback.message&.chat&.id || callback.from&.id
  bot.api.send_message(
    chat_id: chat_id,
    text: onboarding_instructions(language, bot_username)
  )
  true
end

def onboarding_instructions(language, bot_username)
  username = bot_username || 'bot_username'
  bot_mention = "@#{username}"

  if language == 'en'
    <<~TEXT
      Language: English

      How to use the bot:
      In private chat, send Twitter/X, Instagram, or Spotify links directly.
      In group chats, mention the bot before commands: #{bot_mention}

      Private chat commands:
      я нахожусь в Бельгии
      время
      время 21:00
      где я
      напомни время 21:00 по Киеву reminder text
      фото https://x.com/.../status/...
      https://open.spotify.com/track/...

      Notes:
      Twitter/X and Instagram links are downloaded as media.
      Spotify track links are converted to a YouTube link.
      Time and reminder commands currently use Russian wording.
    TEXT
  else
    <<~TEXT
      Язык: русский

      Как пользоваться ботом:
      В личке можно просто отправить ссылку на Twitter/X, Instagram или Spotify.
      В групповых чатах перед командами упоминайте бота: #{bot_mention}

      Команды в личке:
      я нахожусь в Бельгии
      время
      время 21:00
      где я
      напомни время 21:00 по Киеву текст напоминания
      фото https://x.com/.../status/...
      https://open.spotify.com/track/...

      Примечания:
      Twitter/X и Instagram-ссылки бот скачивает как медиа.
      Spotify-ссылки бот превращает в YouTube-ссылку.
    TEXT
  end
end
