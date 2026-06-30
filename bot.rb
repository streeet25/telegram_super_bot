#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

%w[config runtime_helpers reminders spotify_youtube instagram ytdlp twitter time_locations media_jobs onboarding].each do |file|
  require_relative File.join("lib", "telegram_instwitter_bot", file)
end

Telegram::Bot::Client.run(TOKEN) do |bot|
  puts "Bot started..."

  # Fetch bot info to know its username.
  bot_info = bot.api.get_me
  bot_username = bot_info.respond_to?(:username) ? bot_info.username : nil
  puts "Bot username: @#{bot_username}" if bot_username

  if DROP_PENDING_UPDATES_ON_START
    begin
      bot.api.delete_webhook(drop_pending_updates: true)
      puts "Dropped pending Telegram updates on startup."
    rescue => e
      puts "Could not drop pending Telegram updates: #{e.class}: #{e.message}"
    end
  end

  reminder_thread = Thread.new do
    loop do
      begin
        processed = check_due_reminders(bot)
        puts "Checked reminders: #{processed} processed" if processed > 0
      rescue => e
        puts "Error in reminder thread: #{e.message}"
      end
      sleep 30  # Check every 30 seconds
    end
  end

  media_queue = SizedQueue.new(MEDIA_QUEUE_SIZE)
  start_media_workers(bot, media_queue)
  puts "Media workers: #{MEDIA_WORKER_COUNT}, queue size: #{MEDIA_QUEUE_SIZE}"

  bot.listen do |message|
    begin
      if message.is_a?(Telegram::Bot::Types::CallbackQuery)
        next if handle_language_callback(bot, message, bot_username)
        next
      end

      next unless message.is_a?(Telegram::Bot::Types::Message)

      text = message.text || message.caption || ""
      chat_id = message.chat.id
      user_id = message.from&.id.to_s if message.from
      private_chat = private_chat?(message)

      # Check whether the message addresses this bot.
      is_bot_mentioned = bot_username && text.include?("@#{bot_username}")
      is_bot_addressed = private_chat || is_bot_mentioned
      command_text = is_bot_mentioned ? text.gsub("@#{bot_username}", "").strip : text.strip

      if bot_command?(text, %w[start], bot_username: bot_username, private_chat: private_chat)
        if private_chat
          send_language_selection(bot, chat_id)
        else
          bot.api.send_message(
            chat_id: chat_id,
            text: "Напишите мне в личку: /start\nOpen private chat with me and send /start."
          )
        end
        next
      end

      if bot_command?(text, %w[help помощь], bot_username: bot_username, private_chat: private_chat)
        language = user_id ? get_user_language(user_id) : DEFAULT_ONBOARDING_LANGUAGE
        bot.api.send_message(chat_id: chat_id, text: onboarding_instructions(language, bot_username))
        next
      end

      # Handle reminder commands.
      if is_bot_addressed
        # Check if it's a reminder command
        if command_text.match?(/^(?:задрочи|оповести|напомни)\b/i)
          reminder_info = parse_reminder_command(command_text)

          if reminder_info
            # Get user's location if no specific location in the command
            user_location = get_user_location(user_id) if user_id && !reminder_info[:location]

            # Add the reminder
            reminder = add_reminder(chat_id, user_id, reminder_info, user_location)

            # Format response
            time_str = format_reminder_time(reminder['time'], reminder['timezone'])

            bot.api.send_message(
              chat_id: chat_id,
              text: "✅ Напоминание установлено на #{time_str}.\nСообщение: #{reminder['message']}"
            )
            next
          else
            # If the command format is incorrect, provide help
            if command_text.match?(/^(?:задрочи|оповести|напомни)\b/i)
              bot.api.send_message(
                chat_id: chat_id,
                text: "❌ Неверный формат команды.\nПример: @#{bot_username} напомни время 21:00 по Киеву ЭТО НАПОМИНАНИЕ"
              )
              next
            end
          end
        end
      end

      # --- 1) Location updates ---
      if is_bot_addressed && command_text.downcase.include?("я нахожусь в")
        location = detect_location(command_text)
        if location && user_id
          set_user_location(user_id, location)

          location_name = case location
                          when 'Europe/Moscow' then "Москве"
                          when 'Europe/Kiev' then "Киеве"
                          when 'Europe/Brussels' then "Бельгии"
                          end

          bot.api.send_message(
            chat_id: chat_id,
            text: "✅ Запомнил, что вы находитесь в #{location_name}."
          )
          next
        end
      end

      # --- 2) Time conversion requests ---
      is_time_request = is_bot_addressed &&
        (command_text.downcase.match?(/время(\s+\d{1,2}(?::\d{2})?)?/) ||
          command_text.start_with?("/time") ||
          command_text.start_with?("/время"))

      if is_time_request && user_id
        user_location = get_user_location(user_id)

        if user_location
          response = convert_time(command_text, user_location)
        else
          response = convert_time(command_text) +
            "\n\n❗ Чтобы конвертировать конкретное время, сначала сообщите где вы находитесь." +
            "\nНапример: \"@#{bot_username} я нахожусь в Бельгии\""
        end

        bot.api.send_message(
          chat_id: chat_id,
          text: response
        )
        next
      end

      # --- 3) Current location checks ---
      if is_bot_addressed && (
        command_text.downcase.include?("где я") ||
          command_text.downcase.include?("мое местоположение") ||
          command_text.start_with?("/mylocation"))

        if user_id && (location = get_user_location(user_id))
          location_name = case location
                          when 'Europe/Moscow' then "Москве"
                          when 'Europe/Kiev' then "Киеве"
                          when 'Europe/Brussels' then "Бельгии"
                          end

          bot.api.send_message(
            chat_id: chat_id,
            text: "📍 Вы находитесь в #{location_name}"
          )
        else
          bot.api.send_message(
            chat_id: chat_id,
            text: "❌ Я не знаю, где вы находитесь. Укажите ваше местоположение командой:" +
              "\n\"@#{bot_username} я нахожусь в [Москве/Киеве/Бельгии]\""
          )
        end
        next
      end

      # --- 4) Twitter photo commands ---
      if is_bot_addressed && command_text.downcase.include?("фото")
        twitter_links = limit_media_links(bot, chat_id, extract_media_links(command_text, TWITTER_REGEX))
        if twitter_links.any?
          twitter_links.each do |link|
            enqueue_media_job(media_queue, bot, chat_id, { type: :twitter_photo, chat_id: chat_id, link: link })
          end
          next
        end
      end

      # --- 5) Spotify links ---
      spotify_links = limit_media_links(bot, chat_id, extract_media_links(text, SPOTIFY_TRACK_REGEX))
      spotify_links.each do |link|
        enqueue_media_job(media_queue, bot, chat_id, { type: :spotify_youtube, chat_id: chat_id, link: link })
      end

      # --- 1) Twitter / X links ---
      twitter_links = limit_media_links(bot, chat_id, extract_media_links(text, TWITTER_REGEX))
      twitter_links.each do |link|
        enqueue_media_job(media_queue, bot, chat_id, { type: :twitter_video, chat_id: chat_id, link: link })
      end

      # --- 2) Instagram links ---
      instagram_links = limit_media_links(bot, chat_id, extract_media_links(text, INSTAGRAM_REGEX))
      instagram_links.each do |link|
        enqueue_media_job(media_queue, bot, chat_id, { type: :instagram_video, chat_id: chat_id, link: link })
      end
    rescue => e
      puts "Unhandled message error: #{e.class}: #{e.message}"
    end
  end
end
