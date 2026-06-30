# frozen_string_literal: true

def find_executable(executable_name)
  ENV["PATH"].split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir, executable_name)
    return path if File.file?(path) && File.executable?(path)
  end
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
