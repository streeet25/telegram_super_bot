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

# Detects a supported location from message text.
def detect_location(text)
  text_lower = text.downcase

  if text_lower.include?('бельги') || text_lower.include?('брюссел')
    return 'Europe/Brussels'
  elsif text_lower.include?('киев') || text_lower.include?('київ')
    return 'Europe/Kiev'
  elsif text_lower.include?('москв') || text_lower.include?('мск')
    return 'Europe/Moscow'
  end

  nil
end

# Converts time between supported time zones.
def convert_time(text, user_location = nil)
  # Look for a specific time after the localized time keyword.
  time_match = text.match(/время\s+(\d{1,2})(?::(\d{2}))?/i)

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
    case user_location
    when 'Europe/Moscow'
      response += "#{time_str} по Москве соответствует:\n"
    when 'Europe/Kiev'
      response += "#{time_str} по Киеву соответствует:\n"
    when 'Europe/Brussels'
      response += "#{time_str} по Брюсселю соответствует:\n"
    end
  else
    response += "Текущее время:\n"
  end

  # Add time zone and daylight-saving information.
  moscow_dst = moscow_tz.dst?(moscow_time) ? " (летнее)" : ""
  kyiv_dst = kyiv_tz.dst?(kyiv_time) ? " (летнее)" : ""
  brussels_dst = brussels_tz.dst?(brussels_time) ? " (летнее)" : ""

  response += "🇷🇺 Москва#{moscow_dst}: #{moscow_time.strftime('%H:%M')}\n"
  response += "🇺🇦 Киев#{kyiv_dst}: #{kyiv_time.strftime('%H:%M')}\n"
  response += "🇧🇪 Брюссель#{brussels_dst}: #{brussels_time.strftime('%H:%M')}"

  # Add dates when converted times fall on different dates.
  dates = []
  dates << "Москва: #{moscow_time.strftime('%d.%m.%Y')}" if moscow_time.to_date != kyiv_time.to_date || moscow_time.to_date != brussels_time.to_date
  dates << "Киев: #{kyiv_time.strftime('%d.%m.%Y')}" if kyiv_time.to_date != moscow_time.to_date || kyiv_time.to_date != brussels_time.to_date
  dates << "Брюссель: #{brussels_time.strftime('%d.%m.%Y')}" if brussels_time.to_date != moscow_time.to_date || brussels_time.to_date != kyiv_time.to_date

  if dates.any?
    response += "\n\n📅 Даты:\n#{dates.join("\n")}"
  end

  response
end
