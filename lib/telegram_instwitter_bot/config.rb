# frozen_string_literal: true

require 'telegram/bot'
require 'faraday'
require 'json'
require 'fileutils'
require 'securerandom'
require 'open3'
require 'uri'
require 'base64'
require 'tzinfo'     # Time zone support
require 'tzinfo/data' # Time zone and DST data
require 'time'
require 'thread'
require 'tmpdir'

# Work around telegram-bot-ruby 2.2.0 autoload ordering for callback queries.
require 'telegram/bot/types/message'
require 'telegram/bot/types/inaccessible_message'
require 'telegram/bot/types/callback_query'

APP_ROOT = File.expand_path("../..", __dir__)

TOKEN = ENV.fetch("TELEGRAM_BOT_TOKEN") do
  abort "TELEGRAM_BOT_TOKEN is required. Export it before starting the bot."
end

# Stores user location preferences.
USER_LOCATION_FILE = 'user_locations.json'

# Stores onboarding language preferences.
USER_LANGUAGE_FILE = 'user_languages.json'

# Finds Twitter/X links in incoming messages.
TWITTER_REGEX = %r{
  (https?://           # http:// or https://
    (?:www\.)?         # Optional www. prefix
    (?:twitter|x)\.com # twitter.com or x.com
    /[^\s]+)           # Link path until whitespace
}ix

INSTAGRAM_REGEX = %r{
  (https?://(?:www\.|m\.)?instagram\.com
    /(?:
      (?:reel|reels|p|tv)/[^/?\s]+
      | share/(?:
          (?:reel|reels|p|tv)/[^/?\s]+
          | [A-Za-z0-9_-]+
        )
    )
    (?:/\S*)?)
}ix

YOUTUBE_SHORTS_REGEX = %r{
  (https?://(?:www\.|m\.)?youtube\.com
    /shorts/
    [A-Za-z0-9_-]+
    (?:[/?#]\S*)?)
}ix

SPOTIFY_TRACK_REGEX = %r{
  (https?://open\.spotify\.com
    /(?:intl-[a-z]{2}/)?
    track/[A-Za-z0-9]+
    (?:[/?#]\S*)?)
}ix

# Constants for reminder storage
REMINDERS_FILE = 'reminders.json'

# Reminder command format detection regex
REMINDER_REGEX = /^(?:задрочи|оповести|напомни)\s+время\s+(\d{1,2})(?::(\d{2}))?\s*(?:по\s+(.+?))?\s+(.+)$/i
ENGLISH_REMINDER_REGEX = %r{^/?remind(?:\s+me)?(?:\s+(?:at|time))?\s+(\d{1,2})(?::(\d{2}))?\s*(?:(?:in|for)\s+(.+?))?\s+(.+)$}i

MAX_MEDIA_LINKS_PER_MESSAGE = [(ENV["MAX_MEDIA_LINKS_PER_MESSAGE"] || "2").to_i, 1].max
MEDIA_QUEUE_SIZE = [(ENV["MEDIA_QUEUE_SIZE"] || "4").to_i, 1].max
MEDIA_WORKER_COUNT = [[(ENV["MEDIA_WORKER_COUNT"] || "1").to_i, 1].max, 4].min

YTDLP_MAX_FILESIZE_MB = [(ENV["YTDLP_MAX_FILESIZE_MB"] || "96").to_i, 0].max
YTDLP_MAX_FILESIZE_BYTES = YTDLP_MAX_FILESIZE_MB.positive? ? YTDLP_MAX_FILESIZE_MB * 1024 * 1024 : nil
YTDLP_MAX_DOWNLOAD_FILESIZE_MB = [(ENV["YTDLP_MAX_DOWNLOAD_FILESIZE_MB"] || "150").to_i, 0].max
YTDLP_MAX_DOWNLOAD_FILESIZE_BYTES = YTDLP_MAX_DOWNLOAD_FILESIZE_MB.positive? ? YTDLP_MAX_DOWNLOAD_FILESIZE_MB * 1024 * 1024 : nil
YTDLP_MAX_DURATION_SECONDS = [(ENV["YTDLP_MAX_DURATION_SECONDS"] || "600").to_i, 0].max
YTDLP_PROBE_TIMEOUT_SECONDS = [(ENV["YTDLP_PROBE_TIMEOUT_SECONDS"] || "20").to_i, 5].max
YTDLP_DOWNLOAD_TIMEOUT_SECONDS = [(ENV["YTDLP_DOWNLOAD_TIMEOUT_SECONDS"] || "90").to_i, 15].max
YTDLP_SOCKET_TIMEOUT_SECONDS = [(ENV["YTDLP_SOCKET_TIMEOUT_SECONDS"] || "15").to_i, 5].max
FFMPEG_TIMEOUT_SECONDS = [(ENV["FFMPEG_TIMEOUT_SECONDS"] || "120").to_i, 15].max
SCREENSHOT_TIMEOUT_SECONDS = [(ENV["SCREENSHOT_TIMEOUT_SECONDS"] || "30").to_i, 5].max
API_HTTP_TIMEOUT_SECONDS = [(ENV["API_HTTP_TIMEOUT_SECONDS"] || "10").to_i, 3].max
YOUTUBE_SEARCH_RESULTS = [[(ENV["YOUTUBE_SEARCH_RESULTS"] || "5").to_i, 1].max, 10].min
DOWNLOAD_DIR_LIMIT_MULTIPLIER = 2
ENABLE_INSTAGRAM_LEGACY_FETCH = ENV["ENABLE_INSTAGRAM_LEGACY_FETCH"] == "1"
DROP_PENDING_UPDATES_ON_START = ENV["TELEGRAM_DROP_PENDING_UPDATES_ON_START"] == "1"

class MediaDownloadBlocked < StandardError; end
class MediaWithoutVideo < StandardError; end

CommandResult = Struct.new(:stdout, :stderr, :status, :timed_out, :limit_exceeded, keyword_init: true)
