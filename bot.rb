#!/usr/bin/env ruby
# encoding: utf-8

require 'telegram/bot'
require 'faraday'
require 'json'
require 'fileutils'
require 'securerandom'
require 'open3'
require 'tzinfo'     # Для работы с часовыми поясами
require 'tzinfo/data' # Для данных о часовых поясах и DST
require 'time'
require 'thread'
require 'tmpdir'

TOKEN = '7618785354:AAHNWC6a5aOKL_jVaigwUkAKzbg0L5PVa_k'

# Константа для файла хранения данных пользователей
USER_LOCATION_FILE = 'user_locations.json'

# Регулярное выражение для поиска ссылок на Twitter
TWITTER_REGEX = %r{
  (https?://           # Протокол http:// или https://
    (?:www\.)?         # Необязательная часть: www.
    (?:twitter|x)\.com # twitter.com или x.com
    /[^\s]+)           # Любые символы, кроме пробела, до конца ссылки
}ix

INSTAGRAM_REGEX = %r{
  (https?://(?:www\.)?instagram\.com
    /(?:reel|p|tv)
    /[^/?\s]+
    (?:/\S*)?)
}ix

# Constants for reminder storage
REMINDERS_FILE = 'reminders.json'

# Reminder command format detection regex
REMINDER_REGEX = /^(?:задрочи|оповести|напомни)\s+время\s+(\d{1,2})(?::(\d{2}))?\s*(?:по\s+(.+?))?\s+(.+)$/i

# Functions for managing reminders

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
  return nil unless match

  hours = match[1].to_i
  minutes = match[2] ? match[2].to_i : 0
  location = match[3]
  message = match[4].strip

  {
    hours: hours,
    minutes: minutes,
    location: normalize_location(location),
    message: message
  }
end

def normalize_location(location_text)
  return nil unless location_text

  location_text = location_text.downcase
  if location_text.match?(/москв|мск/i)
    'Europe/Moscow'
  elsif location_text.match?(/киев|київ/i)
    'Europe/Kiev'
  elsif location_text.match?(/бельги|брюссел/i)
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
        text: "⏰ НАПОМИНАНИЕ: #{reminder['message']}"
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
def format_reminder_time(time_str, timezone)
  time = Time.parse(time_str)
  tz = TZInfo::Timezone.get(timezone)
  local_time = tz.utc_to_local(time.utc)

  # Get timezone abbreviation/name
  timezone_name = case timezone
                  when 'Europe/Moscow'
                    'Москве'
                  when 'Europe/Kiev'
                    'Киеву'
                  when 'Europe/Brussels'
                    'Брюсселю'
                  else
                    timezone
                  end

  "#{local_time.strftime('%H:%M')} по #{timezone_name}"
end


module InstagramEndpoints
  GetByPost    = "/"               # GET /<postId>
  GetByGraphQL = "/some/graphql/endpoint"  # POST
end

class InstagramClient
  BASE_URL = "https://www.instagram.com"

  def initialize
    @conn = Faraday.new(url: BASE_URL) do |f|
      f.request :url_encoded
      f.adapter Faraday.default_adapter
    end
  end

  def get_post_page_html(post_id)
    @conn.get("#{InstagramEndpoints::GetByPost}#{post_id}") do |req|
      req.headers["accept"]         = "*/*"
      req.headers["host"]           = "www.instagram.com"
      req.headers["referer"]        = "https://www.instagram.com/"
      req.headers["DNT"]            = "1"
      req.headers["Sec-Fetch-Dest"] = "document"
      req.headers["Sec-Fetch-Mode"] = "navigate"
      req.headers["Sec-Fetch-Site"] = "same-origin"
      req.headers["User-Agent"]     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    end.body
  end

  def get_post_graphql_data(post_id)
    encoded_data = encode_graphql_request_data(post_id)
    response = @conn.post(InstagramEndpoints::GetByGraphQL) do |req|
      req.body = encoded_data
      req.headers["Accept"]          = "*/*"
      req.headers["Content-Type"]    = "application/x-www-form-urlencoded"
      req.headers["X-CSRFToken"]     = "RVDUooU5MYsBbS1CNN3CzVAuEP8oHB52"
      req.headers["X-IG-App-ID"]     = "1217981644879628"
      req.headers["X-FB-LSD"]        = "AVqbxe3J_YA"
      req.headers["User-Agent"]      = "Mozilla/5.0"
    end
    JSON.parse(response.body)
  end

  private

  def encode_graphql_request_data(post_id)
    doc_id = "123456789012345"  # пример ID
    variables = { "postId" => post_id }

    URI.encode_www_form(
      "doc_id" => doc_id,
      "variables" => variables.to_json
    )
  end
end


def download_instagram_video_legacy(post_url)
  begin
    puts "Instagram-ссылка: #{post_url}"
    uri = URI.parse(post_url)
    post_id = uri.path.sub("/", "")  # упрощённо: "/p/abc123" => "p/abc123"

    client = InstagramClient.new

    # 1) Если нужно, загружаем HTML
    page_html = client.get_post_page_html(post_id)
    # (Можно доп. логику, если нужно.)

    # 2) Запрашиваем GraphQL
    graphql_data = client.get_post_graphql_data(post_id)
    # Ищем video_url
    video_url = dig_instagram_video_url(graphql_data)
    return nil unless video_url

    # 3) Скачиваем
    file_name = SecureRandom.hex(10) + ".mp4"
    tmp_dir   = File.join(Dir.tmpdir, "ig_video_#{Time.now.to_i}_#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(tmp_dir)

    puts "Скачиваем файл: #{video_url}"
    response = Faraday.get(video_url)
    if response.status == 200
      download_path = File.join(tmp_dir, file_name)
      File.open(download_path, "wb") { |f| f.write(response.body) }
      puts "Instagram видео => #{download_path}"
      return download_path
    else
      puts "Ошибка HTTP при загрузке видео: #{response.status}"
      return nil
    end
  rescue => e
    puts "Ошибка при скачивании Instagram: #{e.message}"
    return nil
  end
end

# Пример «раскопки» JSON — в реальном коде нужно смотреть фактическую структуру
def dig_instagram_video_url(graphql_data)
  media = graphql_data.dig("data", "post", "media")
  return nil unless media && media["is_video"]
  media["video_url"]
end

def find_executable(executable_name)
  ENV["PATH"].split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir, executable_name)
    return path if File.file?(path) && File.executable?(path)
  end
  nil
end

def extract_tweet_id(twitter_url)
  match = twitter_url.match(%r{/(?:status|statuses)/(\d+)})
  match && match[1]
end

def download_twitter_screenshot(twitter_url)
  tweet_id = extract_tweet_id(twitter_url)
  return nil unless tweet_id

  python_path = find_executable("python3")
  return nil unless python_path

  script_path = File.expand_path("scripts/tweet_screenshot.py", __dir__)
  return nil unless File.file?(script_path)

  tmp_dir = Dir.mktmpdir("tw_shot_")
  output_path = File.join(tmp_dir, "#{tweet_id}.png")
  embed_url = "https://platform.twitter.com/embed/Tweet.html?id=#{tweet_id}"

  stdout, stderr, status = Open3.capture3(python_path, script_path, embed_url, output_path)
  unless status.success?
    error_output = stderr.strip.empty? ? stdout.strip : stderr.strip
    puts "tweet screenshot error: #{error_output}"
    FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
    return nil
  end

  return output_path if File.exist?(output_path)

  FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
  nil
end

def transcode_video_to_fit(input_path, max_filesize_bytes)
  return input_path unless max_filesize_bytes && File.size(input_path) > max_filesize_bytes

  ffmpeg_path = find_executable("ffmpeg")
  unless ffmpeg_path
    puts "ffmpeg not found; cannot reduce video size."
    return nil
  end

  base_dir = File.dirname(input_path)
  base_name = File.basename(input_path, ".*")
  steps = [
    { height: 720, crf: 28 },
    { height: 720, crf: 30 },
    { height: 480, crf: 30 },
    { height: 480, crf: 32 },
    { height: 360, crf: 32 }
  ]

  steps.each do |step|
    output_path = File.join(base_dir, "#{base_name}_#{step[:height]}p_crf#{step[:crf]}.mp4")
    cmd = [
      ffmpeg_path,
      "-y",
      "-i", input_path,
      "-vf", "scale=-2:#{step[:height]}:force_original_aspect_ratio=decrease",
      "-c:v", "libx264",
      "-preset", "veryfast",
      "-crf", step[:crf].to_s,
      "-c:a", "aac",
      "-b:a", "128k",
      output_path
    ]

    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      error_output = stderr.strip.empty? ? stdout.strip : stderr.strip
      puts "ffmpeg error (#{step[:height]}p): #{error_output}" unless error_output.empty?
      File.delete(output_path) if File.exist?(output_path)
      next
    end

    if File.size(output_path) <= max_filesize_bytes
      File.delete(input_path) if File.exist?(input_path)
      return output_path
    end

    File.delete(output_path) if File.exist?(output_path)
  end

  nil
end

def download_video_with_ytdlp(post_url, tmp_prefix)
  ytdlp_path = find_executable("yt-dlp")
  return nil unless ytdlp_path

  max_filesize_mb = (ENV["YTDLP_MAX_FILESIZE_MB"] || "48").to_i
  max_filesize_mb = 0 if max_filesize_mb.negative?
  max_filesize_bytes = max_filesize_mb.positive? ? max_filesize_mb * 1024 * 1024 : nil

  format_candidates = ["best"]

  cookies_file = ENV["YTDLP_COOKIES_FILE"]
  cookies_file = nil if cookies_file && cookies_file.strip.empty?
  cookies_browser = ENV["YTDLP_COOKIES_FROM_BROWSER"]
  cookies_browser = nil if cookies_browser && cookies_browser.strip.empty?

  format_candidates.each do |format|
    tmp_dir = Dir.mktmpdir(tmp_prefix)
    output_template = File.join(tmp_dir, "%(id)s.%(ext)s")
    cmd = [
      ytdlp_path,
      "--no-playlist",
      "--no-warnings",
      "--no-progress",
      "-f", format,
      "-o", output_template
    ]
    if cookies_file
      cmd.concat(["--cookies", cookies_file])
    elsif cookies_browser
      cmd.concat(["--cookies-from-browser", cookies_browser])
    end
    cmd << post_url

    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      error_output = stderr.strip.empty? ? stdout.strip : stderr.strip
      puts "yt-dlp error (format #{format}): #{error_output}" unless error_output.empty?
      FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
      next
    end

    candidates = Dir.glob(File.join(tmp_dir, "*")).select do |path|
      File.file?(path) && File.extname(path).downcase != ".part"
    end
    if candidates.empty?
      puts "yt-dlp did not produce a video file."
      FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
      next
    end

    selected = candidates.find { |path| File.extname(path).downcase == ".mp4" } || candidates.first
    adjusted = transcode_video_to_fit(selected, max_filesize_bytes)
    if adjusted
      return adjusted
    end

    FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
    next
  end

  nil
end

def download_instagram_video_with_ytdlp(post_url)
  download_video_with_ytdlp(post_url, "ig_video_")
end

def download_instagram_video(post_url)
  video_path = download_instagram_video_with_ytdlp(post_url)
  return video_path if video_path

  puts "yt-dlp unavailable or failed; falling back to legacy Instagram fetch."
  download_instagram_video_legacy(post_url)
end

def download_twitter_video(twitter_url)
  download_video_with_ytdlp(twitter_url, "tw_video_")
end

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

# Определяем местоположение из текста сообщения
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

# Функция для конвертации времени
def convert_time(text, user_location = nil)
  # Ищем указание конкретного времени (например: "время 21:00" или "время 21")
  time_match = text.match(/время\s+(\d{1,2})(?::(\d{2}))?/i)

  # Получаем объекты всех трех часовых поясов
  moscow_tz = TZInfo::Timezone.get('Europe/Moscow')
  kyiv_tz = TZInfo::Timezone.get('Europe/Kiev')
  brussels_tz = TZInfo::Timezone.get('Europe/Brussels')

  # Начинаем с текущего UTC времени
  now_utc = Time.now.utc

  # Если указано конкретное время и известно местоположение пользователя
  if time_match && user_location
    hours = time_match[1].to_i
    minutes = time_match[2] ? time_match[2].to_i : 0

    # Определяем часовой пояс пользователя
    user_tz = case user_location
              when 'Europe/Moscow' then moscow_tz
              when 'Europe/Kiev' then kyiv_tz
              when 'Europe/Brussels' then brussels_tz
              end

    # Преобразуем текущее UTC в локальное в часовом поясе пользователя
    local_now = user_tz.utc_to_local(now_utc)

    # Создаем новое время с той же датой, но указанными часами/минутами
    local_time = Time.new(
      local_now.year, local_now.month, local_now.day,
      hours, minutes, 0, local_now.utc_offset
    )

    # Преобразуем обратно в UTC
    now_utc = local_time.getutc
  end

  # Преобразуем UTC время во все три часовых пояса
  moscow_time = moscow_tz.utc_to_local(now_utc)
  kyiv_time = kyiv_tz.utc_to_local(now_utc)
  brussels_time = brussels_tz.utc_to_local(now_utc)

  # Форматируем ответ
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

  # Добавляем информацию о часовых поясах и летнем времени
  moscow_dst = moscow_tz.dst?(moscow_time) ? " (летнее)" : ""
  kyiv_dst = kyiv_tz.dst?(kyiv_time) ? " (летнее)" : ""
  brussels_dst = brussels_tz.dst?(brussels_time) ? " (летнее)" : ""

  response += "🇷🇺 Москва#{moscow_dst}: #{moscow_time.strftime('%H:%M')}\n"
  response += "🇺🇦 Киев#{kyiv_dst}: #{kyiv_time.strftime('%H:%M')}\n"
  response += "🇧🇪 Брюссель#{brussels_dst}: #{brussels_time.strftime('%H:%M')}"

  # Добавляем даты, если они различаются
  dates = []
  dates << "Москва: #{moscow_time.strftime('%d.%m.%Y')}" if moscow_time.to_date != kyiv_time.to_date || moscow_time.to_date != brussels_time.to_date
  dates << "Киев: #{kyiv_time.strftime('%d.%m.%Y')}" if kyiv_time.to_date != moscow_time.to_date || kyiv_time.to_date != brussels_time.to_date
  dates << "Брюссель: #{brussels_time.strftime('%d.%m.%Y')}" if brussels_time.to_date != moscow_time.to_date || brussels_time.to_date != kyiv_time.to_date

  if dates.any?
    response += "\n\n📅 Даты:\n#{dates.join("\n")}"
  end

  response
end

# ---------------------------------------------------------------------------
# Запуск бота
# ---------------------------------------------------------------------------
Telegram::Bot::Client.run(TOKEN) do |bot|
  puts "Бот запущен..."

  # Получаем информацию о боте, чтобы знать его username
  bot_info = bot.api.get_me
  bot_username = "VideoMorph_bot" rescue nil
  puts "Бот запущен с именем: @#{bot_username}" if bot_username

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



  bot.listen do |message|
    next unless message.is_a?(Telegram::Bot::Types::Message)

    text = message.text || message.caption || ""
    chat_id = message.chat.id
    user_id = message.from&.id.to_s if message.from

    # Проверяем, обращаются ли к боту
    is_bot_mentioned = bot_username && text.include?("@#{bot_username}")

    # Новый блок: Обработка команды напоминания
    if is_bot_mentioned
      # Remove the bot mention from the text for easier parsing
      command_text = text.gsub("@#{bot_username}", "").strip

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

    # --- 1) Обработка указания местоположения ---
    if is_bot_mentioned && text.downcase.include?("я нахожусь в")
      location = detect_location(text)
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

    # --- 2) Обработка запроса времени ---
    is_time_request = is_bot_mentioned &&
      (text.downcase.match?(/время(\s+\d{1,2}(?::\d{2})?)?/) ||
        text.start_with?("/time") ||
        text.start_with?("/время"))

    if is_time_request && user_id
      user_location = get_user_location(user_id)

      if user_location
        response = convert_time(text, user_location)
      else
        response = convert_time(text) +
          "\n\n❗ Чтобы конвертировать конкретное время, сначала сообщите где вы находитесь." +
          "\nНапример: \"@#{bot_username} я нахожусь в Бельгии\""
      end

      bot.api.send_message(
        chat_id: chat_id,
        text: response
      )
      next
    end

    # --- 3) Проверка текущего местоположения ---
    if is_bot_mentioned && (
      text.downcase.include?("где я") ||
        text.downcase.include?("мое местоположение") ||
        text.start_with?("/mylocation"))

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

    # --- 4) Фото команды для Twitter ---
    if is_bot_mentioned && text.downcase.include?("фото")
      twitter_links = text.scan(TWITTER_REGEX).flatten
      if twitter_links.any?
        twitter_links.each do |link|
          screenshot_path = download_twitter_screenshot(link)
          if screenshot_path && File.exist?(screenshot_path)
            begin
              bot.api.send_photo(
                chat_id: chat_id,
                photo: Faraday::UploadIO.new(screenshot_path, "image/png"),
                caption: "Фото из Twitter"
              )
            rescue => e
              puts "Ошибка отправки в Telegram (Twitter фото): #{e.message}"
            ensure
              File.delete(screenshot_path) if File.exist?(screenshot_path)
              Dir.rmdir(File.dirname(screenshot_path)) rescue nil
            end
          end
        end
        next
      end
    end

    # --- 1) Twitter / X ссылки ---
    twitter_links = text.scan(TWITTER_REGEX).flatten
    twitter_links.each do |link|
      video_path = download_twitter_video(link)
      if video_path && File.exist?(video_path)
        begin
          bot.api.send_video(
            chat_id: chat_id,
            video: Faraday::UploadIO.new(video_path, "video/mp4"),
            caption: "Видео из Twitter"
          )
        rescue => e
          puts "Ошибка отправки в Telegram (Twitter): #{e.message}"
        ensure
          # Удаляем временные файлы
          File.delete(video_path) if File.exist?(video_path)
          Dir.rmdir(File.dirname(video_path)) rescue nil
        end
      end
    end

    # --- 2) Instagram ссылки ---
    instagram_links = text.scan(INSTAGRAM_REGEX).flatten
    instagram_links.each do |link|
      # Пытаемся скачать видео
      video_path = download_instagram_video(link)

      if video_path && File.exist?(video_path)
        # Успешно скачано — отправляем
        begin
          bot.api.send_video(
            chat_id: chat_id,
            video: Faraday::UploadIO.new(video_path, "video/mp4"),
            caption: "Видео из Instagram"
          )
        rescue => e
          bot.api.send_message(chat_id: chat_id, text: "Ошибка при отправке видео: #{e.message}")
        ensure
          # Удаляем временные файлы
          File.delete(video_path) if File.exist?(video_path)
          Dir.rmdir(File.dirname(video_path)) rescue nil
        end

      end
    end
  end
end
