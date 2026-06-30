# frozen_string_literal: true

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
