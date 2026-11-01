# frozen_string_literal: true

ENV['TELEGRAM_BOT_TOKEN'] = '000:upload-tests'
ENV['YTDLP_MAX_FILESIZE_MB'] = '96' # Existing production setting must be safe too.
require_relative '../lib/telegram_instwitter_bot/config'
require_relative '../lib/telegram_instwitter_bot/runtime_helpers'
require_relative '../lib/telegram_instwitter_bot/ytdlp'
require_relative '../lib/telegram_instwitter_bot/media_jobs'
require_relative '../lib/telegram_instwitter_bot/video_feed'

def check(condition, description); raise description unless condition; end
check(YTDLP_MAX_FILESIZE_MB == 49, 'Old 96 MB setting bypasses the public API cap')

def uploaded_message
  Telegram::Bot::Types::Message.new(message_id: 901, date: 1,
    chat: { id: 10, type: 'private' },
    video: { file_id: 'compressed-file', file_unique_id: 'unique-compressed', width: 1280, height: 720, duration: 3 })
end

requests, notices = [], []
mode, attempt = :recover, 0
stubs = Faraday::Adapter::Test::Stubs.new do |stub|
  stub.post('/bot000:upload-tests/sendVideo') do |env|
    attempt += 1
    body = env.body.respond_to?(:read) ? env.body.read : env.body.to_s
    check(body.include?('name="video"'), 'Missing multipart video')
    requests << body.bytesize
    raise IOError, 'uncertain timeout' if mode == :timeout

    if mode == :reject || attempt == 1
      check(@video_feed.stats.fetch('queued', 0) == 0, 'Feed item queued before confirmed upload') if mode == :recover
      [413, {}, JSON.generate(ok: false, error_code: 413, description: 'Request Entity Too Large')]
    else
      [200, {}, JSON.generate(ok: true, result: uploaded_message.to_h)]
    end
  end
  stub.post('/bot000:upload-tests/editMessageCaption') do |env|
    params = URI.decode_www_form(env.body).to_h
    check(params['caption'] == 'Видео из Instagram', 'Status leaked into forwarded caption')
    Telegram::Bot::Types::InlineKeyboardMarkup.new(JSON.parse(params.fetch('reply_markup'), symbolize_names: true))
    [200, {}, JSON.generate(ok: true, result: uploaded_message.to_h)]
  end
  stub.post('/bot000:upload-tests/sendMessage') do |env|
    notices << URI.decode_www_form(env.body).to_h.fetch('text')
    [200, {}, JSON.generate(ok: true, result: uploaded_message.to_h)]
  end
end
api = Telegram::Bot::Api.new('000:upload-tests')
api.instance_variable_set(:@connection, Faraday.new do |builder|
  builder.request :multipart
  builder.request :url_encoded
  builder.adapter :test, stubs
end)
bot = Struct.new(:api).new(api)

Dir.mktmpdir('upload-smoke-') do |dir|
  Dir.chdir(dir) do
    fixture = File.join(dir, 'source.mp4')
    output, status = Open3.capture2e('ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i',
      'testsrc2=size=1280x720:rate=24:duration=3', '-an', '-c:v', 'libx264', '-preset', 'ultrafast',
      '-crf', '10', '-pix_fmt', 'yuv420p', fixture)
    check(status.success?, "Fixture failed: #{output}")
    now = 1800000000
    @video_feed = VideoFeed.new(path: File.join(dir, 'feed.json'), api: api, channel_id: -10042,
                               username: 'pobo4ka_ink', clock: -> { now })
    @video_feed.set_preference('user:10', enabled: true)
    path = File.join(Dir.mktmpdir('ig_video_upload_'), 'original.mp4')
    FileUtils.cp(fixture, path)
    original_key = "sha256:#{Digest::SHA256.file(path).hexdigest}"
    send_video_file(bot, 10, path, 'Видео из Instagram', 'Instagram', source_link: 'https://www.instagram.com/reels/fixture/',
      feed_control: { submitter: 'user:10', chat_id: 10, choice: :default },
      feed_context: @video_feed.submission_context('user:10', private_chat: false))
    check(attempt == 2 && requests.last < requests.first, '413 did not produce exactly one smaller retry')
    check(notices.empty?, 'Recoverable 413 was sent to the user')
    check(!Dir.exist?(File.dirname(path)), 'Temporary media leaked')
    check(recent_sent_videos(10, 10).size == 1, 'History duplicated failed upload')
    jobs = JSON.parse(File.read(File.join(dir, 'feed.json')))['jobs']
    check(jobs.size == 1 && jobs.first['status'] == 'queued', 'Feed lost or duplicated confirmed video')
    check(jobs.first['keys'].include?(original_key), 'Original duplicate fingerprint was lost')
    check(jobs.first['keys'].count { |key| key.start_with?('sha256:') } == 2, 'Compressed duplicate fingerprint was lost')

    mode, attempt = :reject, 0
    path = File.join(Dir.mktmpdir('ig_video_upload_'), 'rejected.mp4')
    FileUtils.cp(fixture, path)
    send_video_file(bot, 10, path, '', 'Instagram')
    check(attempt == 2, 'Repeated 413 caused an unbounded retry')
    check(notices.size == 1 && !notices.first.match?(/413|API has returned/), 'Technical 413 leaked to the user')
    check(recent_sent_videos(10, 10).size == 1, 'Rejected video entered history')
    check(!Dir.exist?(File.dirname(path)), 'Rejected upload leaked temporary files')

    mode, attempt = :timeout, 0
    path = File.join(Dir.mktmpdir('ig_video_upload_'), 'timeout.mp4')
    FileUtils.cp(fixture, path)
    send_video_file(bot, 10, path, '', 'Instagram')
    check(attempt == 1, 'Ambiguous timeout was retried')
    check(@video_feed.stats['queued'] == 1, 'Failed upload changed feed queue')
  end
end
stubs.verify_stubbed_calls
puts 'PASS: native Telegram 413, real ffmpeg smaller retry, clean error, exactly-once history/feed, no timeout retry; no network'
