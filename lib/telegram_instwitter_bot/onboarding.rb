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

def onboarding_command?(text)
  text.to_s.strip.match?(%r{\A/(?:start|help|помощь)(?:@\w+)?(?:\s|$)}i)
end

def language_selection_markup
  keyboard = [[
    Telegram::Bot::Types::InlineKeyboardButton.new(text: 'RU', callback_data: "#{LANGUAGE_CALLBACK_PREFIX}ru"),
    Telegram::Bot::Types::InlineKeyboardButton.new(text: 'EN', callback_data: "#{LANGUAGE_CALLBACK_PREFIX}en")
  ]]

  Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
end

def send_language_selection(bot, chat_id, bot_username = nil)
  puts "Sending onboarding language selection: chat_id=#{chat_id}"
  bot.api.send_message(
    chat_id: chat_id,
    text: "Выберите язык / Choose a language:",
    reply_markup: language_selection_markup
  )
rescue => e
  puts "Onboarding language selection failed: #{e.class}: #{e.message}"
  send_onboarding_instructions(bot, chat_id, DEFAULT_ONBOARDING_LANGUAGE, bot_username)
end

def send_onboarding_instructions(bot, chat_id, language, bot_username)
  puts "Sending onboarding instructions: chat_id=#{chat_id} language=#{language}"
  bot.api.send_message(
    chat_id: chat_id,
    text: onboarding_instructions(language, bot_username)
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
  send_onboarding_instructions(bot, chat_id, language, bot_username)
  true
end

def onboarding_instructions(language, bot_username)
  username = bot_username || 'bot_username'
  bot_mention = "@#{username}"

  if language == 'en'
    <<~TEXT
      Language: English

      How to use it:
      In private chat, send Twitter/X, Instagram, YouTube Shorts, or Spotify links directly.
      In group chats, mention the bot before commands: #{bot_mention}
      Group example: #{bot_mention} time 21:00

      Commands:

      Command: I am in Belgium
      What it does: saves your location for time conversion and reminders.
      Example: I am in Kyiv

      Command: time
      What it does: shows current time in Moscow, Kyiv, and Brussels.
      Example: time

      Command: time 21:00
      What it does: converts 21:00 from your saved location to the other cities.
      Example: time 21:00

      Command: where am I
      What it does: shows the location saved for you.
      Example: where am I

      Command: remind me at 21:00 in Kyiv text
      What it does: creates a reminder. If today's time has passed, it schedules tomorrow.
      Example: remind me at 21:00 in Kyiv call Alex

      Command: photo https://x.com/.../status/...
      What it does: sends a tweet screenshot/photo.
      Example: photo https://x.com/user/status/123

      Command: photo dark https://x.com/.../status/...
      What it does: sends a tweet screenshot/photo in dark mode.
      Example: photo dark https://x.com/user/status/123

      Command: Twitter/X, Instagram, or YouTube Shorts link
      What it does: downloads media from the post. Send 2–10 supported video links in one message to receive one media-group post.
      Example: https://www.youtube.com/shorts/...

      Command: assemble post from last 3 videos
      What it does: creates one post from the most recent 2–10 videos previously sent by the bot in this chat.

      Photos: send photos in private chat, one by one or as albums. Then send a separate command:
      Command: assemble post (or /post)
      What it does: combines your new photos into a forwardable album (up to 10). One photo is sent on its own.
      Command: assemble post from last 3 photos
      What it does: selects your last 3 photos in this chat. Captions and order are preserved. Successfully assembled photos are not included in the next plain "assemble post".
      Command: assemble post from today / assemble post from last 2 hours
      What it does: selects your saved photos by the time you sent them, including previously assembled photos. "Today" starts at midnight Moscow time (UTC+3). At most 10 photos; choose a shorter period if there are more.
      Send images as photos, not files. Group photos are saved silently without a mention; mention the bot only in the command. It must be an admin or have Privacy Mode disabled to receive ordinary group photos. Photos missed before this update must be resent.

      Command: Spotify track link
      What it does: finds a matching YouTube link.
      Example: https://open.spotify.com/track/...
    TEXT
  else
    <<~TEXT
      Язык: русский

      Как пользоваться:
      В личке можно просто отправить ссылку на Twitter/X, Instagram, YouTube Shorts или Spotify.
      В групповых чатах перед командами упоминайте бота: #{bot_mention}
      Пример для группы: #{bot_mention} время 21:00

      Команды:

      Команда: я нахожусь в Бельгии
      Что делает: сохраняет ваше местоположение для конвертации времени и напоминаний.
      Пример: я нахожусь в Киеве

      Команда: время
      Что делает: показывает текущее время в Москве, Киеве и Брюсселе.
      Пример: время

      Команда: время 21:00
      Что делает: переводит 21:00 из вашего сохраненного местоположения в остальные города.
      Пример: время 21:00

      Команда: где я
      Что делает: показывает сохраненное для вас местоположение.
      Пример: где я

      Команда: напомни время 21:00 по Киеву текст
      Что делает: создает напоминание. Если время сегодня уже прошло, ставит на завтра.
      Пример: напомни время 21:00 по Киеву созвон с Алексом

      Команда: фото https://x.com/.../status/...
      Что делает: отправляет скриншот/фото твита.
      Пример: фото https://x.com/user/status/123

      Команда: фото ночной https://x.com/.../status/...
      Что делает: отправляет скриншот/фото твита в ночном режиме.
      Пример: фото ночной https://x.com/user/status/123

      Команда: ссылка Twitter/X, Instagram или YouTube Shorts
      Что делает: скачивает медиа из поста. Отправь 2–10 поддерживаемых видео-ссылок одним сообщением — получишь один пост-альбом.
      Пример: https://www.youtube.com/shorts/...

      Команда: собери пост из последних 3 видео
      Что делает: создает один пост из последних 2–10 видео, которые бот ранее отправил в этот чат.

      Фото: пришли в личку фотографии по одной или альбомами. Затем отдельным сообщением:
      Команда: собери пост (или /post)
      Что делает: собирает твои новые фото в альбом для пересылки (до 10). Одно фото отправляет отдельно.
      Команда: собери пост из последних 3 фото
      Что делает: выбирает последние 3 твоих фото в этом чате. Порядок и подписи сохраняются. Уже собранные фото не попадают в следующую команду «собери пост» без числа.
      Команды: собери пост за сегодня / собери пост за 1 час / собери пост за 2 часа
      Что делает: выбирает сохранённые фото по времени отправки, включая уже собранные. «Сегодня» — с 00:00 по Москве (UTC+3). Максимум 10 фото; если больше — выбери меньший период.
      Присылай изображения как фото, не файлом. Фото в группе сохраняются молча без упоминания; упомяни бота только в команде. Чтобы получать обычные фото группы, бот должен быть администратором или иметь отключённый Privacy Mode. Пропущенные до обновления фото пришли повторно.

      Команда: ссылка на Spotify-трек
      Что делает: находит подходящую YouTube-ссылку.
      Пример: https://open.spotify.com/track/...
    TEXT
  end
end
