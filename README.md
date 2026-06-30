# Telegram Instwitter Bot

A Telegram bot that downloads and sends media from Twitter/X and Instagram links, captures tweet screenshots, converts time between Moscow, Kyiv, and Brussels, and supports simple reminders.

The bot currently understands Russian user commands and replies. Code comments and project documentation are kept in English for easier public maintenance.

## Features

- Downloads Twitter/X videos with `yt-dlp`.
- Downloads Instagram videos with `yt-dlp`.
- Captures tweet screenshots through the Python Playwright helper in `scripts/tweet_screenshot.py`.
- Resolves Spotify track links to a concrete YouTube video link through official APIs.
- Converts time between Moscow, Kyiv, and Brussels.
- Stores per-user location preferences.
- Stores per-user onboarding language preferences.
- Creates reminders from chat commands.
- Limits media download duration, size, queue length, and worker count through environment variables.

## Requirements

- Ruby with Bundler.
- `yt-dlp` available in `PATH`.
- `ffmpeg` available in `PATH` for video compression.
- Python 3 and Playwright for tweet screenshots.
- Spotify application credentials for Spotify-to-YouTube lookup.
- YouTube Data API key for concrete YouTube video lookup.
- A Telegram bot token from BotFather.

## Setup

Install Ruby dependencies:

```sh
bundle install
```

Install screenshot dependencies if you need the Twitter photo command:

```sh
python3 -m pip install playwright
python3 -m playwright install chromium
```

Set the required token:

```sh
export TELEGRAM_BOT_TOKEN="123456:your-token"
```

Optionally copy `.env.example` into your deployment environment and fill in the values. The application reads environment variables directly; it does not load `.env` files by itself.

## Running

```sh
ruby bot.rb
```

The bot stores runtime state in `user_locations.json`, `user_languages.json`, and `reminders.json`. These files are ignored by Git because they contain chat/user state.

## Project Layout

- `bot.rb` starts the Telegram polling loop and routes incoming messages.
- `lib/telegram_instwitter_bot/config.rb` contains requires, constants, and environment-backed settings.
- `lib/telegram_instwitter_bot/reminders.rb` handles reminder parsing, storage, and delivery.
- `lib/telegram_instwitter_bot/onboarding.rb` handles `/start`, language selection, and help text.
- `lib/telegram_instwitter_bot/time_locations.rb` handles user locations and time conversion.
- `lib/telegram_instwitter_bot/media_jobs.rb` owns queue workers and Telegram media sending.
- `lib/telegram_instwitter_bot/ytdlp.rb`, `twitter.rb`, and `instagram.rb` handle media lookup/download helpers.
- `lib/telegram_instwitter_bot/spotify_youtube.rb` resolves Spotify tracks to YouTube video links.

## Commands

In private chat, send `/start` to choose Russian or English and receive usage instructions. You can also send `/help` later to show the instructions again.

Use commands by mentioning the bot in a Telegram group chat. In private chat, the mention is optional.

- `@bot_username я нахожусь в Бельгии`
- `@bot_username время`
- `@bot_username время 21:00`
- `@bot_username где я`
- `@bot_username напомни время 21:00 по Киеву текст напоминания`
- `@bot_username фото https://x.com/.../status/...`
- `@bot_username I am in Belgium`
- `@bot_username time 21:00`
- `@bot_username where am I`
- `@bot_username remind me at 21:00 in Kyiv reminder text`
- `@bot_username photo https://x.com/.../status/...`
- `https://open.spotify.com/track/...`

Plain Twitter/X and Instagram post links are processed as media links. Spotify track links are resolved to a concrete YouTube video link; the bot does not download or send audio files.

## Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | Required | Telegram bot token. Never commit it. |
| `SPOTIFY_CLIENT_ID` | Empty | Spotify application client ID for track metadata lookup. |
| `SPOTIFY_CLIENT_SECRET` | Empty | Spotify application client secret. Never commit it. |
| `SPOTIFY_MARKET` | Empty | Optional Spotify market code, for example `US` or `BE`. |
| `YOUTUBE_API_KEY` | Empty | YouTube Data API key for direct video search. |
| `YOUTUBE_REGION_CODE` | Empty | Optional YouTube search region code, for example `US` or `BE`. |
| `YOUTUBE_SEARCH_RESULTS` | `5` | Number of YouTube candidates to score, capped at `10`. |
| `MAX_MEDIA_LINKS_PER_MESSAGE` | `2` | Maximum media links processed from a single message. |
| `MEDIA_QUEUE_SIZE` | `4` | Maximum queued media jobs. |
| `MEDIA_WORKER_COUNT` | `1` | Number of media worker threads, capped at `4`. |
| `YTDLP_MAX_FILESIZE_MB` | `48` | Maximum media file size. Set `0` to disable the size cap. |
| `YTDLP_MAX_DURATION_SECONDS` | `600` | Maximum video duration. Set `0` to disable the duration cap. |
| `YTDLP_PROBE_TIMEOUT_SECONDS` | `20` | Timeout for metadata probing. |
| `YTDLP_DOWNLOAD_TIMEOUT_SECONDS` | `90` | Timeout for media downloads. |
| `YTDLP_SOCKET_TIMEOUT_SECONDS` | `15` | Network socket timeout passed to `yt-dlp`. |
| `FFMPEG_TIMEOUT_SECONDS` | `120` | Timeout for compression attempts. |
| `SCREENSHOT_TIMEOUT_SECONDS` | `30` | Timeout for tweet screenshot generation. |
| `API_HTTP_TIMEOUT_SECONDS` | `10` | Timeout for Spotify and YouTube HTTP API calls. |
| `YTDLP_FORMAT` | Built-in format | Optional custom `yt-dlp` format selector. |
| `YTDLP_COOKIES_FILE` | Empty | Optional cookies file path for `yt-dlp`. |
| `YTDLP_COOKIES_FROM_BROWSER` | Empty | Optional browser name for `yt-dlp --cookies-from-browser`. |
| `ENABLE_INSTAGRAM_LEGACY_FETCH` | `0` | Enables the legacy Instagram HTTP fallback when set to `1`. |
| `TELEGRAM_DROP_PENDING_UPDATES_ON_START` | `0` | Drops pending Telegram updates on startup when set to `1`. |

## Security Notes

- Keep bot tokens, cookies, and deployment secrets outside the repository.
- If a real Telegram token was ever committed, revoke it in BotFather and create a new one before publishing the repository.
- Do not commit `user_locations.json` or `reminders.json`; they contain runtime chat data.
