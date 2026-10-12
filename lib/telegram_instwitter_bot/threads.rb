# frozen_string_literal: true

require 'uri'

# Only post links, never profiles, searches or lookalike domains. The shared
# short URL is resolved by the extractor against the page's canonical post ID.
THREADS_REGEX = %r{\Ahttps?://(?:www\.)?threads\.(?:com|net)/(?:@[A-Za-z0-9._]+/post|t|share)/[A-Za-z0-9_-]+/?(?:[?#][^\s]*)?\z}i

def normalize_threads_url(link)
  return nil unless link.to_s.match?(THREADS_REGEX)

  uri = URI.parse(link)
  "https://www.threads.com#{uri.path.sub(%r{/\z}, '')}"
rescue URI::InvalidURIError
  nil
end

def download_threads_video(link)
  url = normalize_threads_url(link)
  raise MediaDownloadBlocked, 'Нужна ссылка на отдельный пост Threads с видео.' unless url

  download_video_with_ytdlp(
    url, 'threads_video_', require_success: true, source_name: 'Threads',
    format_candidates: ['best[ext=mp4]/bestvideo[ext=mp4]/best/bestvideo'],
    extra_args: ['--ignore-config', '--no-plugin-dirs', '--plugin-dirs', File.expand_path('../../ytdlp_plugins', __dir__)],
    use_cookies: false
  )
rescue MediaWithoutVideo
  raise MediaDownloadBlocked, 'В этом посте Threads нет собственного видео. Фото, текст и видео из цитат не скачиваю.'
end
