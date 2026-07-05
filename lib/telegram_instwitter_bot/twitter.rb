# frozen_string_literal: true

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
  unless python_path
    raise MediaDownloadBlocked, "Не могу сделать скриншот Twitter/X: на сервере не найден python3."
  end

  script_path = File.join(APP_ROOT, "scripts", "tweet_screenshot.py")
  unless File.file?(script_path)
    raise MediaDownloadBlocked, "Не могу сделать скриншот Twitter/X: не найден scripts/tweet_screenshot.py."
  end

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
    raise MediaDownloadBlocked, "Скриншот Twitter/X делался слишком долго, попробуй позже."
  end

  unless result.status&.success?
    error_output = command_error_output(result)
    puts "tweet screenshot error: #{error_output}"
    FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
    if error_output.match?(/playwright is not installed|No module named ['"]playwright['"]/i)
      raise MediaDownloadBlocked, "Не могу сделать скриншот Twitter/X: на сервере не установлен Playwright."
    end

    raise MediaDownloadBlocked, "Не удалось сделать скриншот Twitter/X. Подробности есть в логах."
  end

  return output_path if File.exist?(output_path)

  FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
  raise MediaDownloadBlocked, "Скриншот Twitter/X не был создан. Подробности есть в логах."
end

def download_twitter_video(twitter_url)
  normalized_url = normalize_twitter_url(twitter_url)
  unless extract_tweet_id(normalized_url)
    raise MediaDownloadBlocked, "Поддерживаю только ссылки на твиты. Twitter/X broadcast/live URL пропускаю."
  end

  download_video_with_ytdlp(normalized_url, "tw_video_", require_success: true, source_name: "Twitter/X")
end
