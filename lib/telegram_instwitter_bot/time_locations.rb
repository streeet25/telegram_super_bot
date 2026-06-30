# frozen_string_literal: true

def load_user_locations
  if File.exist?(USER_LOCATION_FILE)
    JSON.parse(File.read(USER_LOCATION_FILE))
  else
    {}
  end
end

def save_user_locations(locations)
  File.write(USER_LOCATION_FILE, JSON.pretty_generate(locations))
end

def get_user_location(user_id)
  locations = load_user_locations
  locations[user_id.to_s]
end

def set_user_location(user_id, location)
  locations = load_user_locations
  locations[user_id.to_s] = location
  save_user_locations(locations)
end

def location_update_request?(text)
  text_lower = text.to_s.downcase

  text_lower.include?("я нахожусь в") ||
    text_lower.match?(/\b(?:i am|i'm|im)\s+(?:in|at)\b/) ||
    text_lower.match?(/\bmy location is\b/) ||
    text_lower.start_with?("/setlocation")
end

def time_request?(text)
  stripped = text.to_s.strip.downcase

  stripped.match?(/(?:\A|\s)время(?:\s+\d{1,2}(?::\d{2})?)?(?:\s|\z)/) ||
    stripped.match?(%r{\A/(?:time|время)(?:\s|\z)}) ||
    stripped.match?(/\A(?:time|what time)(?:\s+\d{1,2}(?::\d{2})?)?(?:\s|\z)/)
end

def current_location_request?(text)
  text_lower = text.to_s.downcase

  text_lower.include?("где я") ||
    text_lower.include?("мое местоположение") ||
    text_lower.start_with?("/mylocation") ||
    text_lower.match?(/\bwhere am i\b/) ||
    text_lower.match?(/\bmy location\b/) ||
    text_lower.start_with?("/whereami") ||
    text_lower.start_with?("/location")
end

def twitter_photo_request?(text)
  text.to_s.match?(/(?:\A|\s)(?:фото|photo|screenshot)(?:\s|\z)/i)
end

def location_name(location, language = 'ru')
  if language == 'en'
    case location
    when 'Europe/Moscow' then 'Moscow'
    when 'Europe/Kiev' then 'Kyiv'
    when 'Europe/Brussels' then 'Belgium'
    end
  else
    case location
    when 'Europe/Moscow' then 'Москве'
    when 'Europe/Kiev' then 'Киеве'
    when 'Europe/Brussels' then 'Бельгии'
    end
  end
end

# Detects a supported location from message text.
def detect_location(text)
  text_lower = text.downcase

  if text_lower.include?('бельги') || text_lower.include?('брюссел') ||
      text_lower.include?('belgium') || text_lower.include?('brussels')
    return 'Europe/Brussels'
  elsif text_lower.include?('киев') || text_lower.include?('київ') ||
      text_lower.include?('kyiv') || text_lower.include?('kiev')
    return 'Europe/Kiev'
  elsif text_lower.include?('москв') || text_lower.include?('мск') ||
      text_lower.include?('moscow') || text_lower.include?('msk')
    return 'Europe/Moscow'
  end

  nil
end

# Converts time between supported time zones.
def convert_time(text, user_location = nil, language = 'ru')
  # Look for a specific time after the localized time keyword.
  time_match = text.match(%r{(?:\A/?|\s)(?:время|time)\s+(\d{1,2})(?::(\d{2}))?}i)

  # Load all supported time zones.
  moscow_tz = TZInfo::Timezone.get('Europe/Moscow')
  kyiv_tz = TZInfo::Timezone.get('Europe/Kiev')
  brussels_tz = TZInfo::Timezone.get('Europe/Brussels')

  # Start from the current UTC time.
  now_utc = Time.now.utc

  # If a specific time and user location are known, interpret the time there.
  if time_match && user_location
    hours = time_match[1].to_i
    minutes = time_match[2] ? time_match[2].to_i : 0

    # Resolve the user's time zone.
    user_tz = case user_location
              when 'Europe/Moscow' then moscow_tz
              when 'Europe/Kiev' then kyiv_tz
              when 'Europe/Brussels' then brussels_tz
              end

    # Convert current UTC time to the user's local time zone.
    local_now = user_tz.utc_to_local(now_utc)

    # Create a time on the same date with the requested hour/minute.
    local_time = Time.new(
      local_now.year, local_now.month, local_now.day,
      hours, minutes, 0, local_now.utc_offset
    )

    # Convert back to UTC.
    now_utc = local_time.getutc
  end

  # Convert UTC time to all supported time zones.
  moscow_time = moscow_tz.utc_to_local(now_utc)
  kyiv_time = kyiv_tz.utc_to_local(now_utc)
  brussels_time = brussels_tz.utc_to_local(now_utc)

  # Format the response.
  response = "🕒 "

  if time_match && user_location
    time_str = "#{time_match[1]}:#{time_match[2] || '00'}"
    if language == 'en'
      response += "#{time_str} in #{location_name(user_location, language)} is:\n"
    else
      case user_location
      when 'Europe/Moscow'
        response += "#{time_str} по Москве соответствует:\n"
      when 'Europe/Kiev'
        response += "#{time_str} по Киеву соответствует:\n"
      when 'Europe/Brussels'
        response += "#{time_str} по Брюсселю соответствует:\n"
      end
    end
  else
    response += language == 'en' ? "Current time:\n" : "Текущее время:\n"
  end

  # Add time zone and daylight-saving information.
  dst_label = language == 'en' ? " (DST)" : " (летнее)"
  moscow_dst = moscow_tz.dst?(moscow_time) ? dst_label : ""
  kyiv_dst = kyiv_tz.dst?(kyiv_time) ? dst_label : ""
  brussels_dst = brussels_tz.dst?(brussels_time) ? dst_label : ""

  if language == 'en'
    response += "🇷🇺 Moscow#{moscow_dst}: #{moscow_time.strftime('%H:%M')}\n"
    response += "🇺🇦 Kyiv#{kyiv_dst}: #{kyiv_time.strftime('%H:%M')}\n"
    response += "🇧🇪 Brussels#{brussels_dst}: #{brussels_time.strftime('%H:%M')}"
  else
    response += "🇷🇺 Москва#{moscow_dst}: #{moscow_time.strftime('%H:%M')}\n"
    response += "🇺🇦 Киев#{kyiv_dst}: #{kyiv_time.strftime('%H:%M')}\n"
    response += "🇧🇪 Брюссель#{brussels_dst}: #{brussels_time.strftime('%H:%M')}"
  end

  # Add dates when converted times fall on different dates.
  dates = []
  if language == 'en'
    dates << "Moscow: #{moscow_time.strftime('%d.%m.%Y')}" if moscow_time.to_date != kyiv_time.to_date || moscow_time.to_date != brussels_time.to_date
    dates << "Kyiv: #{kyiv_time.strftime('%d.%m.%Y')}" if kyiv_time.to_date != moscow_time.to_date || kyiv_time.to_date != brussels_time.to_date
    dates << "Brussels: #{brussels_time.strftime('%d.%m.%Y')}" if brussels_time.to_date != moscow_time.to_date || brussels_time.to_date != kyiv_time.to_date
  else
    dates << "Москва: #{moscow_time.strftime('%d.%m.%Y')}" if moscow_time.to_date != kyiv_time.to_date || moscow_time.to_date != brussels_time.to_date
    dates << "Киев: #{kyiv_time.strftime('%d.%m.%Y')}" if kyiv_time.to_date != moscow_time.to_date || kyiv_time.to_date != brussels_time.to_date
    dates << "Брюссель: #{brussels_time.strftime('%d.%m.%Y')}" if brussels_time.to_date != moscow_time.to_date || brussels_time.to_date != kyiv_time.to_date
  end

  if dates.any?
    response += language == 'en' ? "\n\n📅 Dates:\n#{dates.join("\n")}" : "\n\n📅 Даты:\n#{dates.join("\n")}"
  end

  response
end
