#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

%w[config runtime_helpers reminders spotify_youtube instagram ytdlp twitter youtube_shorts time_locations media_jobs onboarding].each do |file|
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
      user_language = user_id ? get_user_language(user_id) : DEFAULT_ONBOARDING_LANGUAGE
      private_chat = private_chat?(message)

      # Check whether the message addresses this bot.
      is_bot_mentioned = bot_username && text.include?("@#{bot_username}")
      is_bot_addressed = private_chat || is_bot_mentioned
      command_text = is_bot_mentioned ? text.gsub("@#{bot_username}", "").strip : text.strip
      if onboarding_command?(text)
        command = text.strip.split(/\s+/, 2).first
        puts "Onboarding command received: command=#{command.inspect} chat_id=#{chat_id} " \
          "chat_type=#{message.chat.type.inspect} user_id=#{user_id.inspect}"
      end

      if bot_command?(text, %w[start], bot_username: bot_username, private_chat: true)
        if private_chat
          send_language_selection(bot, chat_id, bot_username)
        else
          bot.api.send_message(
            chat_id: chat_id,
            text: "Напишите мне в личку: /start\nOpen private chat with me and send /start."
          )
        end
        next
      end

      if bot_command?(text, %w[help помощь], bot_username: bot_username, private_chat: true)
        send_onboarding_instructions(bot, chat_id, user_language, bot_username)
        next
      end

      # Handle reminder commands.
      if is_bot_addressed
        # Check if it's a reminder command
        if reminder_command_text?(command_text)
          reminder_info = parse_reminder_command(command_text)
          reminder_info[:language] ||= user_language if reminder_info

          if reminder_info
            # Get user's location if no specific location in the command
            user_location = get_user_location(user_id) if user_id && !reminder_info[:location]

            # Add the reminder
            reminder = add_reminder(chat_id, user_id, reminder_info, user_location)

            # Format response
            time_str = format_reminder_time(reminder['time'], reminder['timezone'], reminder['language'])

            reminder_response = if reminder['language'] == 'en'
                                  "✅ Reminder set for #{time_str}.\nMessage: #{reminder['message']}"
                                else
                                  "✅ Напоминание установлено на #{time_str}.\nСообщение: #{reminder['message']}"
                                end

            bot.api.send_message(chat_id: chat_id, text: reminder_response)
            next
          else
            # If the command format is incorrect, provide help
            example = user_language == 'en' ? "@#{bot_username} remind me at 21:00 in Kyiv reminder text" : "@#{bot_username} напомни время 21:00 по Киеву ЭТО НАПОМИНАНИЕ"
            error_text = user_language == 'en' ? "❌ Invalid command format.\nExample: #{example}" : "❌ Неверный формат команды.\nПример: #{example}"
            bot.api.send_message(chat_id: chat_id, text: error_text)
            next
          end
        end
      end

      # --- 1) Location updates ---
      if is_bot_addressed && location_update_request?(command_text)
        location = detect_location(command_text)
        if location && user_id
          set_user_location(user_id, location)

          saved_location_name = location_name(location, user_language)
          response = if user_language == 'en'
                       "✅ Saved your location as #{saved_location_name}."
                     else
                       "✅ Запомнил, что вы находитесь в #{saved_location_name}."
                     end

          bot.api.send_message(chat_id: chat_id, text: response)
          next
        end
      end

      # --- 2) Time conversion requests ---
      is_time_request = is_bot_addressed && time_request?(command_text)

      if is_time_request && user_id
        user_location = get_user_location(user_id)

        if user_location
          response = convert_time(command_text, user_location, user_language)
        else
          response = convert_time(command_text, nil, user_language)
          response += if user_language == 'en'
                        "\n\n❗ To convert a specific time, first tell me where you are." \
                          "\nExample: \"@#{bot_username} I am in Belgium\""
                      else
                        "\n\n❗ Чтобы конвертировать конкретное время, сначала сообщите где вы находитесь." \
                          "\nНапример: \"@#{bot_username} я нахожусь в Бельгии\""
                      end
        end

        bot.api.send_message(
          chat_id: chat_id,
          text: response
        )
        next
      end

      # --- 3) Current location checks ---
      if is_bot_addressed && current_location_request?(command_text)

        if user_id && (location = get_user_location(user_id))
          saved_location_name = location_name(location, user_language)
          response = user_language == 'en' ? "📍 You are in #{saved_location_name}" : "📍 Вы находитесь в #{saved_location_name}"

          bot.api.send_message(chat_id: chat_id, text: response)
        else
          response = if user_language == 'en'
                       "❌ I do not know where you are. Set your location with:" \
                         "\n\"@#{bot_username} I am in [Moscow/Kyiv/Belgium]\""
                     else
                       "❌ Я не знаю, где вы находитесь. Укажите ваше местоположение командой:" \
                         "\n\"@#{bot_username} я нахожусь в [Москве/Киеве/Бельгии]\""
                     end
          bot.api.send_message(chat_id: chat_id, text: response)
        end
        next
      end

      # --- 4) Twitter photo commands ---
      if is_bot_addressed && twitter_photo_request?(command_text)
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

      # --- 3) YouTube Shorts links ---
      youtube_shorts_links = limit_media_links(bot, chat_id, extract_media_links(text, YOUTUBE_SHORTS_REGEX))
      youtube_shorts_links.each do |link|
        enqueue_media_job(media_queue, bot, chat_id, { type: :youtube_shorts_video, chat_id: chat_id, link: link })
      end
    rescue => e
      puts "Unhandled message error: #{e.class}: #{e.message}"
    end
  end
end
