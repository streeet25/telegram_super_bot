#!/usr/bin/env ruby
# encoding: utf-8

require 'telegram/bot'
require 'faraday'
require 'json'
require 'fileutils'
require 'securerandom'
require 'open3'
require 'uri'
require 'base64'
require 'tzinfo'     # Time zone support
require 'tzinfo/data' # Time zone and DST data
require 'time'
require 'thread'
require 'tmpdir'

TOKEN = ENV.fetch("TELEGRAM_BOT_TOKEN") do
  abort "TELEGRAM_BOT_TOKEN is required. Export it before starting the bot."
end

# Stores user location preferences.
USER_LOCATION_FILE = 'user_locations.json'

# Finds Twitter/X links in incoming messages.
TWITTER_REGEX = %r{
  (https?://           # http:// or https://
    (?:www\.)?         # Optional www. prefix
    (?:twitter|x)\.com # twitter.com or x.com
    /[^\s]+)           # Link path until whitespace
}ix

INSTAGRAM_REGEX = %r{
  (https?://(?:www\.)?instagram\.com
    /(?:reel|p|tv)
    /[^/?\s]+
    (?:/\S*)?)
}ix

SPOTIFY_TRACK_REGEX = %r{
  (https?://open\.spotify\.com
    /(?:intl-[a-z]{2}/)?
    track/[A-Za-z0-9]+
    (?:[/?#]\S*)?)
}ix

# Constants for reminder storage
REMINDERS_FILE = 'reminders.json'

# Reminder command format detection regex
REMINDER_REGEX = /^(?:задрочи|оповести|напомни)\s+время\s+(\d{1,2})(?::(\d{2}))?\s*(?:по\s+(.+?))?\s+(.+)$/i

MAX_MEDIA_LINKS_PER_MESSAGE = [(ENV["MAX_MEDIA_LINKS_PER_MESSAGE"] || "2").to_i, 1].max
MEDIA_QUEUE_SIZE = [(ENV["MEDIA_QUEUE_SIZE"] || "4").to_i, 1].max
MEDIA_WORKER_COUNT = [[(ENV["MEDIA_WORKER_COUNT"] || "1").to_i, 1].max, 4].min

YTDLP_MAX_FILESIZE_MB = [(ENV["YTDLP_MAX_FILESIZE_MB"] || "48").to_i, 0].max
YTDLP_MAX_FILESIZE_BYTES = YTDLP_MAX_FILESIZE_MB.positive? ? YTDLP_MAX_FILESIZE_MB * 1024 * 1024 : nil
YTDLP_MAX_DURATION_SECONDS = [(ENV["YTDLP_MAX_DURATION_SECONDS"] || "600").to_i, 0].max
YTDLP_PROBE_TIMEOUT_SECONDS = [(ENV["YTDLP_PROBE_TIMEOUT_SECONDS"] || "20").to_i, 5].max
YTDLP_DOWNLOAD_TIMEOUT_SECONDS = [(ENV["YTDLP_DOWNLOAD_TIMEOUT_SECONDS"] || "90").to_i, 15].max
YTDLP_SOCKET_TIMEOUT_SECONDS = [(ENV["YTDLP_SOCKET_TIMEOUT_SECONDS"] || "15").to_i, 5].max
FFMPEG_TIMEOUT_SECONDS = [(ENV["FFMPEG_TIMEOUT_SECONDS"] || "120").to_i, 15].max
SCREENSHOT_TIMEOUT_SECONDS = [(ENV["SCREENSHOT_TIMEOUT_SECONDS"] || "30").to_i, 5].max
API_HTTP_TIMEOUT_SECONDS = [(ENV["API_HTTP_TIMEOUT_SECONDS"] || "10").to_i, 3].max
YOUTUBE_SEARCH_RESULTS = [[(ENV["YOUTUBE_SEARCH_RESULTS"] || "5").to_i, 1].max, 10].min
DOWNLOAD_DIR_LIMIT_MULTIPLIER = 2
ENABLE_INSTAGRAM_LEGACY_FETCH = ENV["ENABLE_INSTAGRAM_LEGACY_FETCH"] == "1"
DROP_PENDING_UPDATES_ON_START = ENV["TELEGRAM_DROP_PENDING_UPDATES_ON_START"] == "1"

class MediaDownloadBlocked < StandardError; end

CommandResult = Struct.new(:stdout, :stderr, :status, :timed_out, :limit_exceeded, keyword_init: true)

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

def safe_send_message(bot, chat_id, text)
  bot.api.send_message(chat_id: chat_id, text: text)
rescue => e
  puts "Ошибка отправки сообщения в Telegram: #{e.class}: #{e.message}"
end

def directory_size_bytes(path)
  return 0 unless path && Dir.exist?(path)

  Dir.glob(File.join(path, "**", "*")).sum do |entry|
    File.file?(entry) ? File.size(entry) : 0
  rescue
    0
  end
end

def terminate_process_group(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
rescue Errno::EPERM, NotImplementedError
  begin
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end
end

def run_command_with_limits(*cmd, timeout_seconds:, watched_dir: nil, max_dir_bytes: nil)
  stdout_data = +""
  stderr_data = +""
  status = nil
  timed_out = false
  limit_exceeded = false

  Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
    stdin.close
    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }
    deadline = Time.now + timeout_seconds

    loop do
      break if wait_thr.join(0.25)

      if Time.now >= deadline
        timed_out = true
        terminate_process_group(wait_thr.pid, "TERM")
        break
      end

      if max_dir_bytes && watched_dir && directory_size_bytes(watched_dir) > max_dir_bytes
        limit_exceeded = true
        terminate_process_group(wait_thr.pid, "TERM")
        break
      end
    end

    unless wait_thr.join(5)
      terminate_process_group(wait_thr.pid, "KILL")
      wait_thr.join
    end

    stdout_data = stdout_reader.value
    stderr_data = stderr_reader.value
    status = wait_thr.value
  end

  CommandResult.new(
    stdout: stdout_data,
    stderr: stderr_data,
    status: status,
    timed_out: timed_out,
    limit_exceeded: limit_exceeded
  )
end

def command_error_output(result)
  error_output = result.stderr.to_s.strip
  error_output.empty? ? result.stdout.to_s.strip : error_output
end

def env_value(name)
  value = ENV[name].to_s.strip
  value.empty? ? nil : value
end

def spotify_track_id(spotify_url)
  uri = URI.parse(spotify_url)
  parts = uri.path.split("/")
  track_index = parts.index("track")
  return nil unless track_index

  parts[track_index + 1]
rescue URI::InvalidURIError
  nil
end

def spotify_configured?
  env_value("SPOTIFY_CLIENT_ID") && env_value("SPOTIFY_CLIENT_SECRET")
end

def youtube_configured?
  env_value("YOUTUBE_API_KEY")
end

def spotify_access_token
  return nil unless spotify_configured?

  if @spotify_access_token && @spotify_access_token_expires_at && @spotify_access_token_expires_at > Time.now + 60
    return @spotify_access_token
  end

  credentials = Base64.strict_encode64("#{env_value("SPOTIFY_CLIENT_ID")}:#{env_value("SPOTIFY_CLIENT_SECRET")}")
  response = Faraday.post("https://accounts.spotify.com/api/token") do |req|
    req.headers["Authorization"] = "Basic #{credentials}"
    req.headers["Content-Type"] = "application/x-www-form-urlencoded"
    req.body = URI.encode_www_form("grant_type" => "client_credentials")
    req.options.open_timeout = API_HTTP_TIMEOUT_SECONDS
    req.options.timeout = API_HTTP_TIMEOUT_SECONDS
  end

  unless response.status == 200
    puts "Spotify token error: HTTP #{response.status} #{response.body}"
    return nil
  end

  data = JSON.parse(response.body)
  @spotify_access_token = data["access_token"]
  @spotify_access_token_expires_at = Time.now + data["expires_in"].to_i
  @spotify_access_token
rescue => e
  puts "Spotify token error: #{e.class}: #{e.message}"
  nil
end

def fetch_spotify_track(spotify_url)
  track_id = spotify_track_id(spotify_url)
  return nil unless track_id

  token = spotify_access_token
  return nil unless token

  query = {}
  query["market"] = env_value("SPOTIFY_MARKET") if env_value("SPOTIFY_MARKET")
  response = Faraday.get("https://api.spotify.com/v1/tracks/#{track_id}", query) do |req|
    req.headers["Authorization"] = "Bearer #{token}"
    req.options.open_timeout = API_HTTP_TIMEOUT_SECONDS
    req.options.timeout = API_HTTP_TIMEOUT_SECONDS
  end

  unless response.status == 200
    puts "Spotify track error: HTTP #{response.status} #{response.body}"
    return nil
  end

  data = JSON.parse(response.body)
  artists = data.fetch("artists", []).map { |artist| artist["name"] }.compact
  {
    id: data["id"],
    name: data["name"],
    artists: artists,
    artist_names: artists.join(", "),
    album: data.dig("album", "name"),
    duration_ms: data["duration_ms"].to_i,
    spotify_url: data.dig("external_urls", "spotify") || spotify_url,
    isrc: data.dig("external_ids", "isrc")
  }
rescue => e
  puts "Spotify track fetch error: #{e.class}: #{e.message}"
  nil
end

def youtube_api_get(path, query)
  api_key = env_value("YOUTUBE_API_KEY")
  return nil unless api_key

  response = Faraday.get("https://www.googleapis.com/youtube/v3/#{path}", query.merge("key" => api_key)) do |req|
    req.options.open_timeout = API_HTTP_TIMEOUT_SECONDS
    req.options.timeout = API_HTTP_TIMEOUT_SECONDS
  end

  unless response.status == 200
    puts "YouTube API error: HTTP #{response.status} #{response.body}"
    return nil
  end

  JSON.parse(response.body)
rescue => e
  puts "YouTube API error: #{e.class}: #{e.message}"
  nil
end

def parse_youtube_duration_seconds(duration)
  match = duration.to_s.match(/\APT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?\z/)
  return nil unless match

  match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_i
end

def youtube_search_videos(query)
  search_query = {
    "part" => "snippet",
    "type" => "video",
    "maxResults" => YOUTUBE_SEARCH_RESULTS.to_s,
    "q" => query,
    "safeSearch" => "none",
    "videoCategoryId" => "10"
  }
  search_query["regionCode"] = env_value("YOUTUBE_REGION_CODE") if env_value("YOUTUBE_REGION_CODE")

  search_data = youtube_api_get("search", search_query)
  ids = (search_data || {}).fetch("items", []).map { |item| item.dig("id", "videoId") }.compact
  return [] if ids.empty?

  videos_data = youtube_api_get(
    "videos",
    "part" => "snippet,contentDetails",
    "id" => ids.join(",")
  )
  (videos_data || {}).fetch("items", []).map do |item|
    {
      id: item["id"],
      title: item.dig("snippet", "title").to_s,
      channel_title: item.dig("snippet", "channelTitle").to_s,
      duration_seconds: parse_youtube_duration_seconds(item.dig("contentDetails", "duration")),
      url: "https://www.youtube.com/watch?v=#{item["id"]}"
    }
  end
end

def normalized_match_text(text)
  text.to_s.downcase.gsub(/[^[:alnum:]\s]/, " ").squeeze(" ").strip
end

def youtube_video_score(track, video)
  title = normalized_match_text(video[:title])
  channel = normalized_match_text(video[:channel_title])
  track_name = normalized_match_text(track[:name])
  main_artist = normalized_match_text(track[:artists].first)
  original_track_name = track_name
  score = 0

  score += 60 if !track_name.empty? && title.include?(track_name)
  score += 35 if !main_artist.empty? && title.include?(main_artist)
  score += 30 if title.include?("official audio")
  score += 22 if title.include?("official video")
  score += 15 if !main_artist.empty? && (channel.include?(main_artist) || channel.include?("topic"))
  score += 8 if title.include?("audio")

  penalties = ["cover", "karaoke", "instrumental", "reaction", "nightcore", "sped up", "slowed", "8d"]
  penalties.each do |word|
    score -= 35 if title.include?(word) && !original_track_name.include?(word)
  end
  score -= 25 if title.include?("live") && !original_track_name.include?("live")
  score -= 20 if title.include?("remix") && !original_track_name.include?("remix")

  if track[:duration_ms].positive? && video[:duration_seconds]
    expected_seconds = track[:duration_ms] / 1000.0
    diff = (video[:duration_seconds] - expected_seconds).abs
    score += 25 if diff <= 5
    score += 15 if diff > 5 && diff <= 10
    score += 5 if diff > 10 && diff <= 30
    score -= 20 if diff > 60
  end

  score
end

def find_youtube_video_for_spotify_track(track)
  query = "#{track[:artist_names]} #{track[:name]} official audio"
  videos = youtube_search_videos(query)
  videos = youtube_search_videos("#{track[:artist_names]} #{track[:name]}") if videos.empty?
  return nil if videos.empty?

  videos.max_by { |video| youtube_video_score(track, video) }
end

def spotify_youtube_message(spotify_url)
  return "Spotify-интеграция не настроена. Укажите SPOTIFY_CLIENT_ID и SPOTIFY_CLIENT_SECRET." unless spotify_configured?
  return "YouTube-поиск не настроен. Укажите YOUTUBE_API_KEY." unless youtube_configured?

  track = fetch_spotify_track(spotify_url)
  return "Не удалось получить данные трека из Spotify." unless track

  video = find_youtube_video_for_spotify_track(track)
  return "Не удалось найти подходящее YouTube-видео для #{track[:artist_names]} - #{track[:name]}." unless video

  [
    "🎵 #{track[:artist_names]} - #{track[:name]}",
    "YouTube: #{video[:url]}",
    "Spotify: #{track[:spotify_url]}"
  ].join("\n")
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
    doc_id = "123456789012345"  # Example ID
    variables = { "postId" => post_id }

    URI.encode_www_form(
      "doc_id" => doc_id,
      "variables" => variables.to_json
    )
  end
end


def download_instagram_video_legacy(post_url)
  unless ENABLE_INSTAGRAM_LEGACY_FETCH
    puts "legacy Instagram fetch disabled; set ENABLE_INSTAGRAM_LEGACY_FETCH=1 to enable"
    return nil
  end

  begin
    puts "Instagram link: #{post_url}"
    uri = URI.parse(post_url)
    post_id = uri.path.sub("/", "")  # Simplified: "/p/abc123" => "p/abc123"

    client = InstagramClient.new

    # 1) Load HTML if needed.
    page_html = client.get_post_page_html(post_id)
    # Add more parsing logic here if needed.

    # 2) Request GraphQL data.
    graphql_data = client.get_post_graphql_data(post_id)
    # Look for video_url.
    video_url = dig_instagram_video_url(graphql_data)
    return nil unless video_url

    # 3) Download the media.
    file_name = SecureRandom.hex(10) + ".mp4"
    tmp_dir   = File.join(Dir.tmpdir, "ig_video_#{Time.now.to_i}_#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(tmp_dir)

    puts "Downloading file: #{video_url}"
    response = Faraday.get(video_url) do |req|
      req.options.open_timeout = YTDLP_SOCKET_TIMEOUT_SECONDS
      req.options.timeout = YTDLP_DOWNLOAD_TIMEOUT_SECONDS
    end
    if response.status == 200
      if YTDLP_MAX_FILESIZE_BYTES && response.body.bytesize > YTDLP_MAX_FILESIZE_BYTES
        raise MediaDownloadBlocked, "Видео больше лимита #{YTDLP_MAX_FILESIZE_MB} МБ, пропускаю."
      end

      download_path = File.join(tmp_dir, file_name)
      File.open(download_path, "wb") { |f| f.write(response.body) }
      puts "Instagram video => #{download_path}"
      return download_path
    else
      puts "HTTP error while downloading video: #{response.status}"
      return nil
    end
  rescue MediaDownloadBlocked
    raise
  rescue => e
    puts "Instagram download error: #{e.message}"
    return nil
  end
end

# Example JSON lookup. Real API responses may require structure-specific parsing.
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

def normalize_twitter_url(twitter_url)
  uri = URI.parse(twitter_url)
  return twitter_url unless uri.host

  if uri.host.downcase.end_with?("x.com")
    uri.host = "twitter.com"
  end
  uri.query = nil
  uri.fragment = nil
  uri.to_s
rescue URI::InvalidURIError
  twitter_url
end

def extract_tweet_id(twitter_url)
  match = twitter_url.match(%r{/(?:status|statuses)/(\d+)})
  match && match[1]
end

def download_twitter_screenshot(twitter_url)
  normalized_url = normalize_twitter_url(twitter_url)
  tweet_id = extract_tweet_id(normalized_url)
  unless tweet_id
    raise MediaDownloadBlocked, "Фото делаю только для ссылок на твиты. Twitter/X broadcast/live URL пропускаю."
  end

  python_path = find_executable("python3")
  return nil unless python_path

  script_path = File.expand_path("scripts/tweet_screenshot.py", __dir__)
  return nil unless File.file?(script_path)

  tmp_dir = Dir.mktmpdir("tw_shot_")
  output_path = File.join(tmp_dir, "#{tweet_id}.png")
  embed_url = "https://platform.twitter.com/embed/Tweet.html?id=#{tweet_id}"

  result = run_command_with_limits(
    python_path,
    script_path,
    embed_url,
    output_path,
    timeout_seconds: SCREENSHOT_TIMEOUT_SECONDS
  )
  if result.timed_out
    puts "tweet screenshot timeout after #{SCREENSHOT_TIMEOUT_SECONDS}s"
    FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
    return nil
  end

  unless result.status&.success?
    error_output = command_error_output(result)
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

    result = run_command_with_limits(*cmd, timeout_seconds: FFMPEG_TIMEOUT_SECONDS)
    if result.timed_out
      puts "ffmpeg timeout after #{FFMPEG_TIMEOUT_SECONDS}s (#{step[:height]}p)"
      File.delete(output_path) if File.exist?(output_path)
      next
    end

    unless result.status&.success?
      error_output = command_error_output(result)
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

def ytdlp_cookie_args
  cookies_file = ENV["YTDLP_COOKIES_FILE"]
  cookies_file = nil if cookies_file && cookies_file.strip.empty?
  cookies_browser = ENV["YTDLP_COOKIES_FROM_BROWSER"]
  cookies_browser = nil if cookies_browser && cookies_browser.strip.empty?

  if cookies_file
    ["--cookies", cookies_file]
  elsif cookies_browser
    ["--cookies-from-browser", cookies_browser]
  else
    []
  end
end

def ytdlp_network_args
  [
    "--socket-timeout", YTDLP_SOCKET_TIMEOUT_SECONDS.to_s,
    "--retries", "1",
    "--fragment-retries", "1"
  ]
end

def parse_ytdlp_json(stdout)
  json_line = stdout.to_s.lines.reverse.map(&:strip).find { |line| line.start_with?("{") }
  return nil unless json_line

  JSON.parse(json_line)
rescue JSON::ParserError => e
  puts "yt-dlp metadata parse error: #{e.message}"
  nil
end

def probe_ytdlp_media_info(ytdlp_path, post_url, cookie_args)
  cmd = [
    ytdlp_path,
    "--no-playlist",
    "--no-warnings",
    "--no-progress",
    "--dump-json",
    "--skip-download",
    *ytdlp_network_args,
    *cookie_args,
    post_url
  ]

  result = run_command_with_limits(*cmd, timeout_seconds: YTDLP_PROBE_TIMEOUT_SECONDS)
  if result.timed_out
    raise MediaDownloadBlocked, "Ссылка слишком долго отдает метаданные. Пропускаю, чтобы не подвесить бота."
  end

  unless result.status&.success?
    error_output = command_error_output(result)
    puts "yt-dlp metadata error: #{error_output}" unless error_output.empty?
    return nil
  end

  parse_ytdlp_json(result.stdout)
end

def live_media_info?(info)
  live_status = info["live_status"].to_s.downcase
  return true if info["is_live"] == true
  return true if %w[is_live is_upcoming was_live post_live].include?(live_status)

  live_status.include?("live") && live_status != "not_live"
end

def media_filesize_bytes(info)
  [info["filesize"], info["filesize_approx"]].compact.map(&:to_i).max
end

def validate_ytdlp_media_info!(info)
  return unless info

  if live_media_info?(info)
    raise MediaDownloadBlocked, "Трансляции и live-видео не скачиваю, чтобы не перегружать сервер."
  end

  duration = info["duration"].to_f
  if YTDLP_MAX_DURATION_SECONDS.positive? && duration.positive? && duration > YTDLP_MAX_DURATION_SECONDS
    minutes = (YTDLP_MAX_DURATION_SECONDS / 60.0).round(1)
    raise MediaDownloadBlocked, "Видео длиннее лимита #{minutes} мин., пропускаю."
  end

  filesize = media_filesize_bytes(info)
  if YTDLP_MAX_FILESIZE_BYTES && filesize && filesize > YTDLP_MAX_FILESIZE_BYTES
    raise MediaDownloadBlocked, "Видео больше лимита #{YTDLP_MAX_FILESIZE_MB} МБ, пропускаю."
  end
end

def download_video_with_ytdlp(post_url, tmp_prefix)
  ytdlp_path = find_executable("yt-dlp")
  return nil unless ytdlp_path

  cookie_args = ytdlp_cookie_args
  media_info = probe_ytdlp_media_info(ytdlp_path, post_url, cookie_args)
  return nil unless media_info

  validate_ytdlp_media_info!(media_info)

  default_format = "best[height<=720][ext=mp4]/best[height<=720]/best[ext=mp4]/best"
  configured_format = ENV["YTDLP_FORMAT"].to_s.strip
  format_candidates = [configured_format.empty? ? default_format : configured_format]

  format_candidates.each do |format|
    tmp_dir = Dir.mktmpdir(tmp_prefix)
    output_template = File.join(tmp_dir, "%(id)s.%(ext)s")
    cmd = [
      ytdlp_path,
      "--no-playlist",
      "--no-warnings",
      "--no-progress",
      "--match-filter", "!is_live",
      "--concurrent-fragments", "1",
      "--merge-output-format", "mp4",
      *ytdlp_network_args,
      "-f", format,
      "-o", output_template
    ]
    cmd.concat(["--max-filesize", "#{YTDLP_MAX_FILESIZE_MB}M"]) if YTDLP_MAX_FILESIZE_BYTES
    cmd.concat(cookie_args)
    cmd << post_url

    max_dir_bytes = YTDLP_MAX_FILESIZE_BYTES ? YTDLP_MAX_FILESIZE_BYTES * DOWNLOAD_DIR_LIMIT_MULTIPLIER : nil
    result = run_command_with_limits(
      *cmd,
      timeout_seconds: YTDLP_DOWNLOAD_TIMEOUT_SECONDS,
      watched_dir: tmp_dir,
      max_dir_bytes: max_dir_bytes
    )
    if result.timed_out
      FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
      raise MediaDownloadBlocked, "Скачивание заняло больше #{YTDLP_DOWNLOAD_TIMEOUT_SECONDS} сек., пропускаю."
    end
    if result.limit_exceeded
      FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
      raise MediaDownloadBlocked, "Файл стал слишком большим во время загрузки, пропускаю."
    end

    unless result.status&.success?
      error_output = command_error_output(result)
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
    adjusted = transcode_video_to_fit(selected, YTDLP_MAX_FILESIZE_BYTES)
    if adjusted
      return adjusted
    end

    FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
    raise MediaDownloadBlocked, "Видео не удалось уложить в лимит #{YTDLP_MAX_FILESIZE_MB} МБ, пропускаю."
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
  normalized_url = normalize_twitter_url(twitter_url)
  unless extract_tweet_id(normalized_url)
    raise MediaDownloadBlocked, "Поддерживаю только ссылки на твиты. Twitter/X broadcast/live URL пропускаю."
  end

  download_video_with_ytdlp(normalized_url, "tw_video_")
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

def clean_media_link(link)
  link.to_s.sub(/[)\].,!?]+\z/, "")
end

def extract_media_links(text, regex)
  text.scan(regex).flatten.map { |link| clean_media_link(link) }.uniq
end

def limit_media_links(bot, chat_id, links)
  return links if links.size <= MAX_MEDIA_LINKS_PER_MESSAGE

  safe_send_message(
    bot,
    chat_id,
    "В одном сообщении обрабатываю первые #{MAX_MEDIA_LINKS_PER_MESSAGE} медиа-ссылки."
  )
  links.first(MAX_MEDIA_LINKS_PER_MESSAGE)
end

def cleanup_media_path(path)
  return unless path

  dir = File.dirname(path)
  if Dir.exist?(dir) && File.basename(dir).match?(/\A(?:tw_video_|ig_video_|tw_shot_)/)
    FileUtils.remove_entry(dir)
  elsif File.exist?(path)
    File.delete(path)
  end
rescue => e
  puts "Ошибка удаления временного файла: #{e.class}: #{e.message}"
end

def send_video_file(bot, chat_id, video_path, caption, source_name)
  return unless video_path && File.exist?(video_path)

  bot.api.send_video(
    chat_id: chat_id,
    video: Faraday::UploadIO.new(video_path, "video/mp4"),
    caption: caption
  )
rescue => e
  puts "Ошибка отправки в Telegram (#{source_name}): #{e.class}: #{e.message}"
  safe_send_message(bot, chat_id, "Ошибка при отправке видео: #{e.message}")
ensure
  cleanup_media_path(video_path)
end

def send_photo_file(bot, chat_id, photo_path, caption, source_name)
  return unless photo_path && File.exist?(photo_path)

  bot.api.send_photo(
    chat_id: chat_id,
    photo: Faraday::UploadIO.new(photo_path, "image/png"),
    caption: caption
  )
rescue => e
  puts "Ошибка отправки в Telegram (#{source_name}): #{e.class}: #{e.message}"
ensure
  cleanup_media_path(photo_path)
end

def process_media_job(bot, job)
  chat_id = job[:chat_id]
  link = job[:link]

  case job[:type]
  when :twitter_photo
    screenshot_path = download_twitter_screenshot(link)
    send_photo_file(bot, chat_id, screenshot_path, "Фото из Twitter", "Twitter фото")
  when :twitter_video
    video_path = download_twitter_video(link)
    send_video_file(bot, chat_id, video_path, "Видео из Twitter", "Twitter")
  when :instagram_video
    video_path = download_instagram_video(link)
    send_video_file(bot, chat_id, video_path, "Видео из Instagram", "Instagram")
  when :spotify_youtube
    safe_send_message(bot, chat_id, spotify_youtube_message(link))
  else
    puts "Unknown media job type: #{job[:type]}"
  end
rescue MediaDownloadBlocked => e
  puts "media blocked (#{job[:type]}): #{e.message}"
  safe_send_message(bot, chat_id, e.message)
rescue => e
  puts "media job error (#{job[:type]}): #{e.class}: #{e.message}"
end

def start_media_workers(bot, media_queue)
  MEDIA_WORKER_COUNT.times.map do |index|
    Thread.new do
      loop do
        begin
          job = media_queue.pop
          process_media_job(bot, job)
        rescue => e
          puts "media worker #{index + 1} error: #{e.class}: #{e.message}"
        end
      end
    end
  end
end

def enqueue_media_job(media_queue, bot, chat_id, job)
  media_queue.push(job, true)
  true
rescue ThreadError
  safe_send_message(bot, chat_id, "Очередь обработки медиа заполнена. Попробуйте позже.")
  false
end

# ---------------------------------------------------------------------------
# Bot startup
# ---------------------------------------------------------------------------
Telegram::Bot::Client.run(TOKEN) do |bot|
  puts "Bot started..."

  # Fetch bot info to know its username.
  bot_info = bot.api.get_me
  bot_username = "VideoMorph_bot" rescue nil
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
      next unless message.is_a?(Telegram::Bot::Types::Message)

    text = message.text || message.caption || ""
    chat_id = message.chat.id
    user_id = message.from&.id.to_s if message.from

    # Check whether the message addresses this bot.
    is_bot_mentioned = bot_username && text.include?("@#{bot_username}")

    # Handle reminder commands.
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

    # --- 1) Location updates ---
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

    # --- 2) Time conversion requests ---
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

    # --- 3) Current location checks ---
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

    # --- 4) Twitter photo commands ---
    if is_bot_mentioned && text.downcase.include?("фото")
      twitter_links = limit_media_links(bot, chat_id, extract_media_links(text, TWITTER_REGEX))
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
