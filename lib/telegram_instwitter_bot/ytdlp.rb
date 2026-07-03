# frozen_string_literal: true

def find_executable(executable_name)
  ENV["PATH"].split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir, executable_name)
    return path if File.file?(path) && File.executable?(path)
  end
  nil
end

def telegram_video_filter(max_height: nil)
  filters = [
    "scale=trunc(iw*sar/2)*2:trunc(ih/2)*2",
    "setsar=1"
  ]
  if max_height
    filters << "scale=-2:min(ih\\,#{max_height})"
    filters << "setsar=1"
  end
  filters.join(",")
end

def transcode_video_for_telegram(input_path, output_path, ffmpeg_path, crf:, max_height: nil)
  cmd = [
    ffmpeg_path,
    "-y",
    "-i", input_path,
    "-map", "0:v:0",
    "-map", "0:a?",
    "-vf", telegram_video_filter(max_height: max_height),
    "-map_metadata", "-1",
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-crf", crf.to_s,
    "-pix_fmt", "yuv420p",
    "-c:a", "aac",
    "-b:a", "128k",
    "-movflags", "+faststart",
    output_path
  ]

  run_command_with_limits(*cmd, timeout_seconds: FFMPEG_TIMEOUT_SECONDS)
end

def prepare_video_for_telegram(input_path, max_filesize_bytes)
  return input_path unless input_path && File.exist?(input_path)

  original_fits = max_filesize_bytes.nil? || File.size(input_path) <= max_filesize_bytes
  ffmpeg_path = find_executable("ffmpeg")
  unless ffmpeg_path
    puts "ffmpeg not found; sending original video without Telegram normalization." if original_fits
    puts "ffmpeg not found; cannot reduce video size." unless original_fits
    return original_fits ? input_path : nil
  end

  base_dir = File.dirname(input_path)
  base_name = File.basename(input_path, ".*")
  steps = [
    { suffix: "telegram", crf: 23, height: nil },
    { suffix: "720p_crf28", crf: 28, height: 720 },
    { suffix: "720p_crf30", crf: 30, height: 720 },
    { suffix: "480p_crf30", crf: 30, height: 480 },
    { suffix: "480p_crf32", crf: 32, height: 480 },
    { suffix: "360p_crf32", crf: 32, height: 360 }
  ]
  transcode_failed = false

  steps.each do |step|
    output_path = File.join(base_dir, "#{base_name}_#{step[:suffix]}.mp4")
    result = transcode_video_for_telegram(
      input_path,
      output_path,
      ffmpeg_path,
      crf: step[:crf],
      max_height: step[:height]
    )

    if result.timed_out
      label = step[:height] ? "#{step[:height]}p" : "normalization"
      puts "ffmpeg timeout after #{FFMPEG_TIMEOUT_SECONDS}s (#{label})"
      File.delete(output_path) if File.exist?(output_path)
      transcode_failed = true
      next
    end

    unless result.status&.success?
      label = step[:height] ? "#{step[:height]}p" : "normalization"
      error_output = command_error_output(result)
      puts "ffmpeg error (#{label}): #{error_output}" unless error_output.empty?
      File.delete(output_path) if File.exist?(output_path)
      transcode_failed = true
      next
    end

    if max_filesize_bytes.nil? || File.size(output_path) <= max_filesize_bytes
      File.delete(input_path) if File.exist?(input_path)
      return output_path
    end

    File.delete(output_path) if File.exist?(output_path)
  end

  if original_fits
    message = transcode_failed ? "could not normalize" : "normalized copy exceeded size limit"
    puts "ffmpeg #{message}; sending original video."
    return input_path
  end

  nil
end

def transcode_video_to_fit(input_path, max_filesize_bytes)
  prepare_video_for_telegram(input_path, max_filesize_bytes)
end

def bytes_to_megabytes(bytes)
  (bytes.to_f / 1024 / 1024).round(1)
end

def download_filesize_limit_bytes
  YTDLP_MAX_DOWNLOAD_FILESIZE_BYTES
end

def download_dir_limit_bytes
  return nil unless YTDLP_MAX_DOWNLOAD_FILESIZE_BYTES

  multiplier = find_executable("ffmpeg") ? DOWNLOAD_DIR_LIMIT_MULTIPLIER : 1
  YTDLP_MAX_DOWNLOAD_FILESIZE_BYTES * multiplier
end

def download_filesize_limit_arg
  limit_bytes = download_filesize_limit_bytes
  return nil unless limit_bytes

  "#{(limit_bytes.to_f / 1024 / 1024).ceil}M"
end

def video_upload_metadata(video_path)
  ffprobe_path = find_executable("ffprobe")
  return {} unless ffprobe_path

  result = run_command_with_limits(
    ffprobe_path,
    "-v", "error",
    "-select_streams", "v:0",
    "-show_entries", "stream=width,height:format=duration",
    "-of", "json",
    video_path,
    timeout_seconds: 10
  )
  return {} unless result.status&.success?

  data = JSON.parse(result.stdout)
  stream = data.fetch("streams", []).first || {}
  format = data["format"] || {}
  metadata = {}

  width = stream["width"].to_i
  height = stream["height"].to_i
  duration = format["duration"].to_f
  metadata[:width] = width if width.positive?
  metadata[:height] = height if height.positive?
  metadata[:duration] = duration.round if duration.positive?
  metadata
rescue JSON::ParserError => e
  puts "ffprobe metadata parse error: #{e.message}"
  {}
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

def ytdlp_auth_failure?(error_output)
  error_output.match?(/cookies|login|sign in|auth|unauthorized|forbidden|HTTP Error (?:401|403)/i)
end

def ytdlp_metadata_failure_message(error_output, source_name:)
  if ytdlp_auth_failure?(error_output)
    "Не удалось получить видео из #{source_name}: похоже, нужны актуальные cookies для yt-dlp."
  else
    "Не удалось получить метаданные видео через yt-dlp. Проверь версию yt-dlp и лог ошибки."
  end
end

def ytdlp_download_failure_message(error_output, source_name:)
  if ytdlp_auth_failure?(error_output)
    "Не удалось скачать видео из #{source_name}: похоже, нужны актуальные cookies для yt-dlp."
  elsif error_output.match?(/File is larger than max-filesize|larger than max-filesize|maximum file size/i)
    "Видео не удалось уложить в лимит скачивания. Попробуй ссылку на более короткое видео или увеличь YTDLP_MAX_FILESIZE_MB."
  else
    "yt-dlp не смог скачать подходящий формат видео. Проверь свежесть yt-dlp и лог ошибки."
  end
end

def probe_ytdlp_media_info(ytdlp_path, post_url, cookie_args, require_success: false, source_name: "этого источника")
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
    raise MediaDownloadBlocked, ytdlp_metadata_failure_message(error_output, source_name: source_name) if require_success

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
  return unless YTDLP_MAX_DOWNLOAD_FILESIZE_BYTES && filesize && filesize > YTDLP_MAX_DOWNLOAD_FILESIZE_BYTES

  message = "yt-dlp metadata size #{bytes_to_megabytes(filesize)} MB exceeds download limit " \
    "#{YTDLP_MAX_DOWNLOAD_FILESIZE_MB} MB"
  message += "; upload limit is #{YTDLP_MAX_FILESIZE_MB} MB" if YTDLP_MAX_FILESIZE_BYTES
  puts message
end

def default_ytdlp_formats
  [
    "best[height<=720][ext=mp4]/best[height<=720]",
    "best[height<=480][ext=mp4]/best[height<=480]",
    "best[height<=360][ext=mp4]/best[height<=360]",
    "best[ext=mp4]/best"
  ]
end

def download_video_with_ytdlp(post_url, tmp_prefix, require_success: false, source_name: "этого источника")
  ytdlp_path = find_executable("yt-dlp")
  unless ytdlp_path
    raise MediaDownloadBlocked, "yt-dlp не найден в PATH, поэтому видео скачать нельзя." if require_success

    return nil
  end

  cookie_args = ytdlp_cookie_args
  media_info = probe_ytdlp_media_info(
    ytdlp_path,
    post_url,
    cookie_args,
    require_success: require_success,
    source_name: source_name
  )
  unless media_info
    raise MediaDownloadBlocked, "Не удалось получить метаданные видео через yt-dlp." if require_success

    return nil
  end

  validate_ytdlp_media_info!(media_info)

  configured_format = ENV["YTDLP_FORMAT"].to_s.strip
  format_candidates = configured_format.empty? ? default_ytdlp_formats : [configured_format]
  filesize_limit_arg = download_filesize_limit_arg
  max_dir_bytes = download_dir_limit_bytes
  last_error_output = nil

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
    cmd.concat(["--max-filesize", filesize_limit_arg]) if filesize_limit_arg
    cmd.concat(cookie_args)
    cmd << post_url

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
      last_error_output = error_output unless error_output.empty?
      FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
      next
    end

    candidates = Dir.glob(File.join(tmp_dir, "*")).select do |path|
      File.file?(path) && File.extname(path).downcase != ".part"
    end
    if candidates.empty?
      puts "yt-dlp did not produce a video file."
      last_error_output = "yt-dlp did not produce a video file."
      FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
      next
    end

    selected = candidates.find { |path| File.extname(path).downcase == ".mp4" } || candidates.first
    adjusted = prepare_video_for_telegram(selected, YTDLP_MAX_FILESIZE_BYTES)
    if adjusted
      return adjusted
    end

    FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
    raise MediaDownloadBlocked, "Видео не удалось уложить в лимит #{YTDLP_MAX_FILESIZE_MB} МБ, пропускаю."
  end

  raise MediaDownloadBlocked, ytdlp_download_failure_message(last_error_output.to_s, source_name: source_name) if require_success

  nil
end

def download_instagram_video_with_ytdlp(post_url)
  download_video_with_ytdlp(post_url, "ig_video_")
end

def download_instagram_video(post_url)
  video_path = download_instagram_video_with_ytdlp(post_url)
  return video_path if video_path

  puts "yt-dlp unavailable or failed; falling back to legacy Instagram fetch."
  legacy_path = download_instagram_video_legacy(post_url)
  prepare_video_for_telegram(legacy_path, YTDLP_MAX_FILESIZE_BYTES)
end
