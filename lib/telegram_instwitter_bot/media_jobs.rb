# frozen_string_literal: true

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
  if Dir.exist?(dir) && File.basename(dir).match?(/\A(?:tw_video_|ig_video_|yt_shorts_|tw_shot_)/)
    FileUtils.remove_entry(dir)
  elsif File.exist?(path)
    File.delete(path)
  end
rescue => e
  puts "Ошибка удаления временного файла: #{e.class}: #{e.message}"
end

def send_video_file(bot, chat_id, video_path, caption, source_name)
  return unless video_path && File.exist?(video_path)

  file_size_mb = (File.size(video_path).to_f / 1024 / 1024).round(1)
  metadata = video_upload_metadata(video_path)
  params = {
    chat_id: chat_id,
    video: Faraday::UploadIO.new(video_path, "video/mp4"),
    caption: caption,
    supports_streaming: true
  }.merge(metadata)

  response = bot.api.send_video(**params)
  message_id = response.respond_to?(:message_id) ? response.message_id : nil
  details = [
    "source=#{source_name}",
    "size=#{file_size_mb}MB",
    ("duration=#{metadata[:duration]}s" if metadata[:duration]),
    ("width=#{metadata[:width]}" if metadata[:width]),
    ("height=#{metadata[:height]}" if metadata[:height]),
    ("message_id=#{message_id}" if message_id)
  ].compact.join(" ")
  puts "Telegram video sent: #{details}"
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
  when :youtube_shorts_video
    video_path = download_youtube_shorts_video(link)
    send_video_file(bot, chat_id, video_path, "Видео из YouTube Shorts", "YouTube Shorts")
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
