# frozen_string_literal: true

require 'uri'
require_relative 'media_errors'

YOUTUBE_VIDEO_MAX_DURATION_SECONDS = 300

def youtube_video_reference(link)
  uri = URI.parse(link.to_s)
  return nil unless %w[http https].include?(uri.scheme) && !uri.userinfo && [80, 443].include?(uri.port)

  host = uri.host.to_s.downcase
  shorts = false
  id = if %w[youtu.be www.youtu.be].include?(host)
         uri.path[%r{\A/([A-Za-z0-9_-]+)/?\z}, 1]
       elsif %w[youtube.com www.youtube.com m.youtube.com music.youtube.com].include?(host)
         if uri.path == '/watch'
           ids = URI.decode_www_form(uri.query.to_s).select { |key, _| key == 'v' }.map(&:last).uniq
           ids.first if ids.one?
         elsif (match = uri.path.match(%r{\A/(shorts|embed|live)/([A-Za-z0-9_-]+)/?\z}))
           shorts = match[1] == 'shorts'
           match[2]
         end
       end
  return nil unless id && id.match?(/\A[A-Za-z0-9_-]+\z/)

  { id: id, shorts: shorts, url: "https://www.youtube.com/watch?v=#{id}" }
rescue URI::InvalidURIError, ArgumentError
  nil
end

def validate_youtube_duration!(value)
  duration = Float(value) rescue nil
  unless duration && duration.finite? && duration.positive?
    raise MediaDownloadBlocked, 'Не удалось проверить длительность YouTube-видео. Скачиваю только ролики до 5 минут.'
  end
  if duration > YOUTUBE_VIDEO_MAX_DURATION_SECONDS
    raise MediaDownloadBlocked, 'YouTube-видео длиннее 5 минут — пропускаю. Пришли ролик до 5 минут включительно.'
  end
end

def download_youtube_video(link)
  reference = youtube_video_reference(link)
  raise MediaDownloadBlocked, 'Пришли ссылку на отдельное YouTube-видео, не на канал или плейлист.' unless reference

  path = download_video_with_ytdlp(reference[:url], 'yt_video_', require_success: true, source_name: 'YouTube') do |info|
    # The shared downloader checks live/video/size limits first. This stricter
    # provider-specific ceiling must not change limits for other providers.
    validate_youtube_duration!(info['duration'])
  end
  # Do not trust rounded upload metadata or a stale extractor duration.
  validate_youtube_duration!(probe_media_streams(path)&.dig('format', 'duration'))
  path
rescue => error
  cleanup_media_path(path) if path
  if error.is_a?(MediaWithoutVideo)
    # Unlike a text-only tweet, an explicit YouTube link must not fail silently.
    raise MediaDownloadBlocked, 'YouTube не отдал видео: оно недоступно или нет подходящего видеоформата.'
  end
  raise
end
