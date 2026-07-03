# frozen_string_literal: true

def normalize_youtube_shorts_url(shorts_url)
  uri = URI.parse(shorts_url)
  return shorts_url unless uri.host

  host = uri.host.downcase
  return shorts_url unless %w[youtube.com www.youtube.com m.youtube.com].include?(host)

  match = uri.path.match(%r{\A/shorts/([A-Za-z0-9_-]+)})
  return shorts_url unless match

  uri.scheme = "https"
  uri.host = "www.youtube.com"
  uri.path = "/shorts/#{match[1]}"
  uri.query = nil
  uri.fragment = nil
  uri.to_s
rescue URI::InvalidURIError
  shorts_url
end

def extract_youtube_shorts_id(shorts_url)
  match = shorts_url.match(%r{youtube\.com/shorts/([A-Za-z0-9_-]+)}i)
  match && match[1]
end

def download_youtube_shorts_video(shorts_url)
  normalized_url = normalize_youtube_shorts_url(shorts_url)
  unless extract_youtube_shorts_id(normalized_url)
    raise MediaDownloadBlocked, "Поддерживаю только ссылки на YouTube Shorts."
  end

  download_video_with_ytdlp(
    normalized_url,
    "yt_shorts_",
    require_success: true,
    source_name: "YouTube Shorts"
  )
end
