# frozen_string_literal: true

def load_reminders
  if File.exist?(REMINDERS_FILE)
    JSON.parse(File.read(REMINDERS_FILE))
  else
    []
  end
end

def save_reminders(reminders)
  File.write(REMINDERS_FILE, JSON.pretty_generate(reminders))
end

def parse_reminder_command(text)
  match = text.match(REMINDER_REGEX)
  language = 'ru'

  unless match
    match = text.match(ENGLISH_REMINDER_REGEX)
    language = 'en' if match
  end

  return nil unless match

  hours = match[1].to_i
  minutes = match[2] ? match[2].to_i : 0
  location = match[3]
  message = match[4].strip

  {
    hours: hours,
    minutes: minutes,
    location: normalize_location(location),
    message: message,
    language: language
  }
end

def reminder_command_text?(text)
  text.to_s.match?(/^(?:задрочи|оповести|напомни|\/?remind(?:\s+me)?)\b/i)
end

def normalize_location(location_text)
  return nil unless location_text

  location_text = location_text.downcase
  if location_text.match?(/москв|мск|moscow|msk/i)
    'Europe/Moscow'
  elsif location_text.match?(/киев|київ|kyiv|kiev/i)
    'Europe/Kiev'
  elsif location_text.match?(/бельги|брюссел|belgium|brussels/i)
    'Europe/Brussels'
  else
    nil
  end
end

def add_reminder(chat_id, user_id, reminder_info, user_location)
  # Determine which timezone to use
  timezone = reminder_info[:location] || user_location || 'UTC'

  # Get timezone object
  tz = TZInfo::Timezone.get(timezone)

  # Current time in the timezone
  now = tz.utc_to_local(Time.now.utc)

  # Create reminder time
  reminder_time = Time.new(
    now.year, now.month, now.day,
    reminder_info[:hours], reminder_info[:minutes], 0,
    now.utc_offset
  )

  # If the time has already passed today, schedule for tomorrow
  reminder_time += 86400 if reminder_time < now

  # Convert to UTC for storage
  utc_time = reminder_time.getutc.iso8601

  # Create reminder object
  reminder = {
    'id' => SecureRandom.hex(10),
    'chat_id' => chat_id,
    'user_id' => user_id.to_s,
    'time' => utc_time,
    'message' => reminder_info[:message],
    'timezone' => timezone,
    'language' => reminder_info[:language] || 'ru',
    'created_at' => Time.now.utc.iso8601
  }

  # Load existing reminders
  reminders = load_reminders

  # Add new reminder
  reminders << reminder

  # Save updated reminders
  save_reminders(reminders)

  # Return the reminder
  reminder
end

def check_due_reminders(bot)
  reminders = load_reminders
  current_time = Time.now.utc

  # Find due reminders
  due_reminders, remaining_reminders = reminders.partition do |reminder|
    Time.parse(reminder['time']) <= current_time
  end

  # Process each due reminder
  due_reminders.each do |reminder|
    begin
      # Send the reminder message
      bot.api.send_message(
        chat_id: reminder['chat_id'],
        text: reminder['language'] == 'en' ? "⏰ REMINDER: #{reminder['message']}" : "⏰ НАПОМИНАНИЕ: #{reminder['message']}"
      )
      puts "Sent reminder: #{reminder['id']} to chat #{reminder['chat_id']}"
    rescue => e
      puts "Error sending reminder: #{e.message}"
    end
  end

  # Save the remaining reminders if any were processed
  if due_reminders.any?
    save_reminders(remaining_reminders)
  end

  # Return count of processed reminders
  due_reminders.size
end

# Format a time string based on timezone
def format_reminder_time(time_str, timezone, language = 'ru')
  time = Time.parse(time_str)
  tz = TZInfo::Timezone.get(timezone)
  local_time = tz.utc_to_local(time.utc)

  # Get timezone abbreviation/name
  timezone_name = if language == 'en'
                    case timezone
                    when 'Europe/Moscow' then 'Moscow'
                    when 'Europe/Kiev' then 'Kyiv'
                    when 'Europe/Brussels' then 'Brussels'
                    else
                      timezone
                    end
                  else
                    case timezone
                    when 'Europe/Moscow' then 'Москве'
                    when 'Europe/Kiev' then 'Киеву'
                    when 'Europe/Brussels' then 'Брюсселю'
                    else
                      timezone
                    end
                  end

  language == 'en' ? "#{local_time.strftime('%H:%M')} in #{timezone_name}" : "#{local_time.strftime('%H:%M')} по #{timezone_name}"
end
