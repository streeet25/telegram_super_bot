# frozen_string_literal: true

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
