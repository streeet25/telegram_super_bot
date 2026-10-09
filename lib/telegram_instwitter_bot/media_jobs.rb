# frozen_string_literal: true

def clean_media_link(link)
  link.to_s.sub(/[)\].,!?]+\z/, "")
end

def extract_media_links(text, regex)
  text.scan(regex).flatten.map { |link| clean_media_link(link) }.uniq
end

def media_source_for_link(link)
  return :twitter if link.match?(TWITTER_REGEX)
  return :instagram if link.match?(INSTAGRAM_REGEX)
  return :youtube_shorts if link.match?(YOUTUBE_SHORTS_REGEX)

  nil
end

def extract_video_link_items(text)
  seen = {}
  items = []
  text.to_s.scan(%r{https?://[^\s]+}i) do |raw_link|
    offset = Regexp.last_match.begin(0)
    prefix = text.to_s[0...offset].split("\n", -1).last.to_s
    signs = prefix[/(?:\A|[[:blank:]])((?:[+\-−–—][[:blank:]]*)+)\z/, 1]
    choice = signs ? (signs.match?(/[-−–—]/) ? :skip : :publish) : :default
    link = clean_media_link(raw_link)
    source = media_source_for_link(link)
    next unless source
    if seen[link]
      # Conflicting occurrences of the same URL must never override a minus.
      existing = seen[link]
      existing[:feed_choice] = if [existing[:feed_choice], choice].include?(:skip)
                                 :skip
                               elsif [existing[:feed_choice], choice].include?(:publish)
                                 :publish
                               else
                                 :default
                               end
      next
    end

    item = { link: link, source: source, feed_choice: choice }
    seen[link] = item
    items << item
  end
  items
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

MEDIA_HISTORY_MUTEX = Mutex.new

def load_media_history
  return {} unless File.exist?(MEDIA_HISTORY_FILE)

  data = JSON.parse(File.read(MEDIA_HISTORY_FILE))
  data.is_a?(Hash) ? data : {}
rescue JSON::ParserError => e
  puts "media history parse error: #{e.message}"
  {}
end

def record_sent_videos(chat_id, messages, sources: [])
  video_entries = []
  Array(messages).each_with_index do |message, index|
    video = message.respond_to?(:video) ? message.video : nil
    file_id = video.respond_to?(:file_id) ? video.file_id : nil
    next if file_id.to_s.empty?

    video_entries << { "file_id" => file_id, "source" => sources[index].to_s, "sent_at" => Time.now.utc.iso8601 }
  end
  return if video_entries.empty?

  MEDIA_HISTORY_MUTEX.synchronize do
    history = load_media_history
    chat_history = Array(history[chat_id.to_s])
    history[chat_id.to_s] = (chat_history + video_entries).last(MAX_MEDIA_HISTORY_PER_CHAT)
    File.write(MEDIA_HISTORY_FILE, JSON.pretty_generate(history))
  end
rescue => e
  puts "media history save error: #{e.class}: #{e.message}"
end

def recent_sent_videos(chat_id, count)
  MEDIA_HISTORY_MUTEX.synchronize { Array(load_media_history[chat_id.to_s]).last(count) }
end

def send_video_file(bot, chat_id, video_path, caption, source_name, feed_context: nil, source_link: nil)
  return unless video_path && File.exist?(video_path)

  file_size_mb = (File.size(video_path).to_f / 1024 / 1024).round(1)
  metadata = video_upload_metadata(video_path)
  params = {
    chat_id: chat_id,
    video: Faraday::UploadIO.new(video_path, "video/mp4"),
    caption: caption,
    supports_streaming: true
  }.merge(metadata)

  feed_keys = feed_context ? video_feed_keys(source_link, video_path) : []
  response = bot.api.send_video(**params)
  record_sent_videos(chat_id, response, sources: [source_name])
  if feed_context
    visuals = video_feed_visuals([video_path], submitter: feed_context[:submitter], one_off: feed_context[:one_off])
    enqueue_video_feed(response, **feed_context, keys: [feed_keys], visuals: visuals)
  end
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

def video_media_payload(media, caption: nil, metadata: {})
  {
    "type" => "video",
    "media" => media,
    "supports_streaming" => true
  }.merge(metadata.transform_keys(&:to_s)).tap do |payload|
    payload["caption"] = caption unless caption.to_s.empty?
  end
end

def send_video_album(bot, chat_id, videos, caption: "", feed_context: nil)
  uploads = {}
  media = videos.each_with_index.map do |video, index|
    attachment_name = "video_#{index}"
    uploads[attachment_name.to_sym] = Faraday::UploadIO.new(video.fetch(:path), "video/mp4")
    video_media_payload(
      "attach://#{attachment_name}",
      caption: index.zero? ? caption : nil,
      metadata: video.fetch(:metadata, {})
    )
  end
  contexts = videos.map { |video| video.fetch(:feed_context, feed_context) }
  feed_keys = videos.each_with_index.map { |video, i| contexts[i] ? video_feed_keys(video[:link], video[:path]) : [] }
  response = bot.api.send_media_group(chat_id: chat_id, media: JSON.generate(media), **uploads)
  record_sent_videos(chat_id, response, sources: videos.map { |video| video[:source] })
  eligible = contexts.each_index.select { |i| contexts[i] }
  unless eligible.empty?
    visuals = video_feed_visuals(eligible.map { |i| videos[i][:path] }, submitter: contexts[eligible.first][:submitter],
                                one_off: eligible.any? { |i| contexts[i][:one_off] })
    eligible.each_with_index do |i, visual_index|
      enqueue_video_feed(Array(response)[i], **contexts[i], keys: [feed_keys[i]], visuals: [visuals[visual_index]])
    end
  end
  response
rescue => e
  puts "Ошибка отправки альбома: #{e.class}: #{e.message}"
  safe_send_message(bot, chat_id, "Не удалось отправить собранный пост: #{e.message}")
  nil
ensure
  videos.each { |video| cleanup_media_path(video[:path]) }
end

def download_video_item(item)
  path = case item.fetch(:source)
         when :twitter then download_twitter_video(item.fetch(:link))
         when :instagram then download_instagram_video(item.fetch(:link))
         when :youtube_shorts then download_youtube_shorts_video(item.fetch(:link))
         end
  return nil unless path

  { path: path, source: item.fetch(:source).to_s, link: item.fetch(:link), metadata: video_upload_metadata(path) }
end

def process_video_link_batch(bot, chat_id, items, feed_context: nil)
  downloaded = items.each_with_object([]) do |item, result|
    video = download_video_item(item)
    if video
      video[:feed_context] = item.fetch(:feed_context, feed_context)
      result << video
    end
  rescue MediaWithoutVideo => e
    puts "media skipped (#{item[:source]}): #{e.message}"
  rescue MediaDownloadBlocked => e
    puts "media blocked (#{item[:source]}): #{e.message}"
    safe_send_message(bot, chat_id, e.message)
  rescue => e
    puts "media batch error (#{item[:source]}): #{e.class}: #{e.message}"
  end

  return if downloaded.empty?

  if downloaded.one?
    video = downloaded.first
    send_video_file(bot, chat_id, video[:path], "Видео из #{video[:source]}", video[:source], feed_context: video[:feed_context], source_link: video[:link])
  else
    send_video_album(bot, chat_id, downloaded, caption: "Подборка из #{downloaded.size} видео", feed_context: feed_context)
  end
end

def send_recent_videos_as_post(bot, chat_id, count)
  videos = recent_sent_videos(chat_id, count)
  if videos.size < count
    safe_send_message(bot, chat_id, "В истории этого чата только #{videos.size} видео. Сначала отправь боту ещё ролики.")
    return
  end

  media = videos.each_with_index.map do |video, index|
    video_media_payload(video.fetch("file_id"), caption: index.zero? ? "Подборка из последних #{count} видео" : nil)
  end
  response = bot.api.send_media_group(chat_id: chat_id, media: JSON.generate(media))
  record_sent_videos(chat_id, response, sources: videos.map { |video| video["source"] })
rescue => e
  puts "recent video post error: #{e.class}: #{e.message}"
  safe_send_message(bot, chat_id, "Не удалось собрать пост из последних видео: #{e.message}")
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
  puts "media job started: type=#{job[:type]}"

  case job[:type]
  when :twitter_photo
    dark_mode = job[:dark_mode] == true
    screenshot_path = download_twitter_screenshot(link, dark_mode: dark_mode)
    caption = dark_mode ? "Фото из Twitter (ночной режим)" : "Фото из Twitter"
    send_photo_file(bot, chat_id, screenshot_path, caption, "Twitter фото")
  when :twitter_video
    video_path = download_twitter_video(link)
    send_video_file(bot, chat_id, video_path, "Видео из Twitter", "Twitter", feed_context: job[:feed_context], source_link: link)
  when :instagram_video
    video_path = download_instagram_video(link)
    send_video_file(bot, chat_id, video_path, "Видео из Instagram", "Instagram", feed_context: job[:feed_context], source_link: link)
  when :youtube_shorts_video
    video_path = download_youtube_shorts_video(link)
    send_video_file(bot, chat_id, video_path, "Видео из YouTube Shorts", "YouTube Shorts", feed_context: job[:feed_context], source_link: link)
  when :spotify_youtube
    safe_send_message(bot, chat_id, spotify_youtube_message(link))
  when :video_link_batch
    process_video_link_batch(bot, chat_id, job.fetch(:items), feed_context: job[:feed_context])
  when :recent_video_post
    send_recent_videos_as_post(bot, chat_id, job.fetch(:count))
  when :photo_post
    send_photo_post(bot, job)
  else
    puts "Unknown media job type: #{job[:type]}"
  end
rescue MediaWithoutVideo => e
  puts "media skipped (#{job[:type]}): #{e.message}"
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
  puts "media job enqueued: type=#{job[:type]} queue_length=#{media_queue.length}"
  true
rescue ThreadError
  safe_send_message(bot, chat_id, "Очередь обработки медиа заполнена. Попробуйте позже.")
  false
end
