# Telegram Instwitter Bot

A Telegram bot that downloads and sends media from Twitter/X, Instagram, and YouTube Shorts links, captures tweet screenshots, converts time between Moscow, Kyiv, and Brussels, and supports simple reminders.

The bot currently understands Russian user commands and replies. Code comments and project documentation are kept in English for easier public maintenance.

## Features

- Downloads Twitter/X videos with `yt-dlp`.
- Downloads Instagram videos with `yt-dlp`.
- Combines 2–10 supported video links from one message into one Telegram media-group post.
- Re-sends a post assembled from the most recently sent videos in the chat.
- Collects user-uploaded photos and assembles forwardable photo albums on request, preserving order and captions.
- Downloads YouTube Shorts videos with `yt-dlp`.
- Normalizes downloaded videos for Telegram-friendly MP4 playback.
- Captures tweet screenshots through the Python Playwright helper in `scripts/tweet_screenshot.py`.
- Resolves Spotify track links to a concrete YouTube video link through official APIs, requiring an artist match to avoid selecting identically named tracks by another artist.
- Converts time between Moscow, Kyiv, and Brussels.
- Stores per-user location preferences.
- Stores per-user onboarding language preferences.
- Creates reminders from chat commands.
- Limits media download duration, size, queue length, and worker count through environment variables.
- Optionally publishes successfully delivered link downloads into an anonymous public video feed, with persistent deduplication, privacy controls and administrator moderation.

## Requirements

- Ruby with Bundler.
- `yt-dlp` available in `PATH`.
- `ffmpeg` available in `PATH` for video normalization and compression.
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
python3 -m venv .venv
. .venv/bin/activate
pip install playwright
python -m playwright install chromium
```

Set `TWITTER_SCREENSHOT_PYTHON` to the venv Python path when the bot service does not run with the venv activated.

Set the required token:

```sh
export TELEGRAM_BOT_TOKEN="123456:your-token"
```

Optionally copy `.env.example` into your deployment environment and fill in the values. The application reads environment variables directly; it does not load `.env` files by itself.

## Running

```sh
ruby bot.rb
```

Production deployment details are in [DEPLOYMENT.md](DEPLOYMENT.md).

The bot stores runtime state in `user_locations.json`, `user_languages.json`, `reminders.json`, `media_history.json`, `photo_history.json`, and `video_feed.json`. These files are ignored by Git because they contain chat/user state.

## Project Layout

- `bot.rb` starts the Telegram polling loop and routes incoming messages.
- `lib/telegram_instwitter_bot/config.rb` contains requires, constants, and environment-backed settings.
- `lib/telegram_instwitter_bot/reminders.rb` handles reminder parsing, storage, and delivery.
- `lib/telegram_instwitter_bot/onboarding.rb` handles `/start`, language selection, and help text.
- `lib/telegram_instwitter_bot/time_locations.rb` handles user locations and time conversion.
- `lib/telegram_instwitter_bot/media_jobs.rb` owns queue workers and Telegram media sending.
- `lib/telegram_instwitter_bot/photo_posts.rb` stores incoming photo file IDs and assembles photo posts, isolated by chat, sender, and forum topic.
- `lib/telegram_instwitter_bot/video_feed.rb` owns the persistent feed queue, deduplication, privacy preferences and moderation.
- `lib/telegram_instwitter_bot/ytdlp.rb`, `twitter.rb`, `instagram.rb`, and `youtube_shorts.rb` handle media lookup/download helpers.
- `lib/telegram_instwitter_bot/spotify_youtube.rb` resolves Spotify tracks to YouTube video links.

## Commands

In private chat, send `/start` to choose Russian or English and receive usage instructions. You can also send `/help` later to show the instructions again.

Use commands by mentioning the bot in a Telegram group chat. In private chat, the mention is optional.

| Command | What it does | Example |
| --- | --- | --- |
| `я нахожусь в Бельгии` / `I am in Belgium` | Saves your location for time conversion and reminders. | `@bot_username I am in Kyiv` |
| `время` / `time` | Shows current time in Moscow, Kyiv, and Brussels. | `@bot_username time` |
| `время 21:00` / `time 21:00` | Converts that time from your saved location to the other cities. | `@bot_username time 21:00` |
| `где я` / `where am I` | Shows your saved location. | `@bot_username where am I` |
| `напомни время 21:00 по Киеву текст` / `remind me at 21:00 in Kyiv text` | Creates a reminder. If today's time has passed, it schedules tomorrow. | `@bot_username remind me at 21:00 in Kyiv call Alex` |
| `фото <tweet>` / `photo <tweet>` | Sends a tweet screenshot/photo. | `@bot_username photo https://x.com/user/status/123` |
| `фото ночной <tweet>` / `photo dark <tweet>` | Sends a tweet screenshot/photo in dark mode. | `@bot_username photo dark https://x.com/user/status/123` |
| 2–10 Twitter/X, Instagram, or YouTube Shorts links | Downloads the videos and sends them as one Telegram media-group post. One link is sent as a normal video. | `https://instagram.com/reel/... https://www.youtube.com/shorts/...` |
| `собери пост из последних 3 видео` | Re-sends the last 2–10 videos previously sent by the bot in this chat as one post. | `@bot_username собери пост из последних 3 видео` |
| `собери пост` / `assemble post` / `/post` | Sends your new uploaded photos as one forwardable album (2–10 photos), or one standalone photo. | Send photos, then send `собери пост` separately. |
| `собери пост из последних 3 фото` / `assemble post from last 3 photos` | Selects the last 1–10 photos sent by you in this chat/topic. | `собери пост из последних 3 фото` |
| `собери пост за сегодня` / `assemble post from today` | Selects your saved photos sent since midnight Moscow time (UTC+3). | `@bot_username собери пост за сегодня` |
| `собери пост за 1 час` / `собери пост за 2 часа` / `assemble post from last 2 hours` | Selects your saved photos sent during the requested number of hours before the command. | `@bot_username собери пост за 2 часа` |
| Spotify track link | Finds a matching YouTube link. | `https://open.spotify.com/track/...` |

Plain Twitter/X, Instagram, and YouTube Shorts links are processed as video links. Telegram post links are ignored. Spotify track links are resolved to a concrete YouTube video link; the bot does not download or send audio files.

### Anonymous video feed (ПОБОЧКА)

Set `VIDEO_FEED_CHANNEL=@pobo4ka_ink` to enable; leave empty to disable. The bot
must be a channel administrator with publish and delete rights. The destination
is resolved to its numeric ID and bound to the state file; changing it without
migrating state fails closed. Successfully downloaded and delivered videos from
supported links are published individually using Telegram file IDs, without
forwarding attribution, captions, submitter names or source-chat titles. Video
pixels/audio/watermarks are unchanged. Uploaded photos/videos, Spotify links,
screenshots and reassembled history are not feed submissions. Old history is not
backfilled. Protected content, bots, automatic discussion forwards and the feed
channel itself are excluded.

Group submissions participate by default. In private chat, `/start`, `/privacy`,
or the first link shows an inline choice. Private submissions are excluded until
the person opts in. Consent on the prompt attached to a new link includes that
message's successfully delivered videos as well as future requests. It works
both before and after download completion: file IDs wait in `awaiting_consent`
and enter the publication queue only after approval. The prompt is bound to its
submitter and submission, valid for 24 hours, and survives restarts. Expired,
unapproved file IDs are removed. Consent never releases unrelated older messages;
generic `/start`/`privacy` buttons and buttons created by older bot versions still
apply only to future requests. **Не публиковать в Побочке** disables all of that person's future
submissions, including groups, and cancels unpublished queued/failed items. The
setting persists until **Публиковать анонимно** is selected. Cancelled items and
old history are never automatically replayed. Existing posts remain in the
channel. Anonymous `sender_chat` submissions are excluded because they cannot be
matched to an individual's privacy preferences or moderation record. Changing
privacy settings also invalidates feed eligibility of downloads already in progress,
except the explicitly approved initial submission. Opting out revokes its consent
token too, so enabling publication again cannot revive that cancelled download.

Per-link controls (private chats and groups):

- `+ URL` (or `+URL`) explicitly authorizes just that video for anonymous public
  publication, including when the user's general setting is off. It does not
  enable future publications or create a generic consent prompt.
- `- URL` (or `-URL`) downloads without submitting that video to the feed,
  regardless of the user's setting or subsequent consent on the other links.
- An unmarked URL retains the usual privacy/consent rules.

Put a sign before **each** URL on the same line. Mixed 1–10-link batches keep
their individual choices even if a download fails or Telegram returns an album.
Unicode minus/dashes (`−`, `–`, `—`) also exclude publication. Conflicting signs
or repeated occurrences of the exact same URL prefer exclusion. Signs within
URL paths/query parameters do not change publication mode. Bans, protected
content exclusions and deduplication apply to `+` too. Pressing the global off
button again cancels queued one-off publications and invalidates their in-flight
download permissions, even if the general setting was already off.

Moderation commands work only in private chat. Each command rechecks that the
caller is the channel owner or an administrator with delete permission:

- `/feed` — queue/error counts and command help (never submitter identities).
- `/feed_ban https://t.me/pobo4ka_ink/123` — block the original submitter of that
  feed post, including pending jobs. Normal bot downloads still work.
- `/feed_unban https://t.me/pobo4ka_ink/123` — allow new submissions again;
  does not revive blocked jobs or override the person's privacy setting.
- `/feed_purge https://t.me/pobo4ka_ink/123` — preview deletion of that blocked
  submitter's published posts; returns a one-use `/feed_confirm TOKEN` command,
  bound to the requesting administrator and valid for five minutes. This is a
  separate destructive operation, never implicit in banning.
- `/feed_retry_failed` — retry explicitly rejected publications; ambiguous
  sends are excluded to avoid duplicates.

Telegram bots can only delete posts younger than 48 hours; older ones need manual
channel moderation ([Bot API](https://core.telegram.org/bots/api#deletemessage)).
Deletion failures and remaining jobs are reported in `/feed`.

The private `video_feed.json` file (mode `0600`) atomically persists file IDs,
hashed canonical URLs/content digests, submitter IDs for moderation, preferences,
bans, retries and channel message IDs. No names, source captions or downloaded
videos are stored. Deduplication covers queued/published/deleted items by URL,
content hash or Telegram unique ID, including across restarts. Confirmed duplicates
contribute their alternative URLs/hashes/Telegram IDs to the existing record, so
subsequent uploads through any known alias are suppressed too. The publisher
rechecks duplicates before sending, including aliases discovered after enqueue.
`/feed` reports the persistent number of skipped duplicate submissions (counted
since the alias-dedup release). Private submissions without consent do not add
new aliases or visual signatures to public records.

Visual deduplication additionally compares 24 sampled frames across the entire
clip, using perceptual hashes, coarse colour and three fixed centre crops.
Near-identical re-encodes, resized copies and modest symmetric edge crops can
match even with different URLs and file IDs. At least 22 frames must agree in
order, with sufficient contrast and motion; shared intros, still templates and
uncertain matches fall back to exact identity. Original visual exemplars are
never replaced by near-copies, preventing gradual similarity drift. Audio is
not compared: the same picture with a different soundtrack can be a duplicate.
Major crops, overlays, edits, time trims and low-motion clips are not guaranteed
to match. This is conservative approximate matching, not a universal detector.

Analysis runs **after** successful delivery to the user, before temporary-file
cleanup. It uses the existing ffmpeg/ffprobe, one decoder thread, an eight-second
per-video subprocess budget and a shared 16-second album budget (plus process
termination/hash computation). Failure/missing tools/timeouts preserve exact
deduplication and do not fail the download. Set `VIDEO_FEED_VISUAL_DEDUP=0` to
skip new frame analysis. Only versioned compact hashes/colour summaries (~3 KiB
per video) are stored in `video_feed.json`, not frames or downloaded media.
The visual index grows from new submissions; old published records gain a
signature when an authorized exact duplicate is seen again. No old videos are
downloaded or republished for backfill. Preserve this state across restarts.

Original replies to the submitting user/chat are unchanged; only the public
feed is deduplicated. The worker has
its own HTTP connection, bounded timeouts and a two-second interval; at most
1,000 publications may wait. Queue overflow logs `Video feed enqueue: full`
and does not affect the original download. Explicit 429/5xx rejections retry
with backoff up to eight attempts. Unknown transport outcomes and interrupted
sends become `uncertain` and are not automatically resent: Telegram provides no
idempotency key. Review the channel and state manually to resolve them. Corrupt
state disables the feed without discarding deduplication or bans. Keep this file
private, backed up and out of Git and container images.

Tests (the smoke scripts use a network-disabled Faraday test adapter):

```sh
ruby test/video_feed_test.rb
ruby test/video_link_choices_test.rb
ruby test/link_controls_announcement_test.rb
ruby test/video_fingerprint_test.rb # Includes generated ffmpeg fixtures; no network.
bundle exec ruby test/video_feed_telegram_smoke.rb
ruby test/photo_posts_test.rb
bundle exec ruby test/photo_posts_telegram_smoke.rb
```

The operator-only `scripts/announce_link_controls.rb` previews the number of
known individual users by default. Run with `--send` only with authorization for
this one-time private update. It never polls updates, sends to groups/channels,
or changes publication preferences. Run from the persistent state directory.
`link_controls_announcement.json` (0600) keeps a fixed recipient snapshot and
delivery receipts: reruns skip delivered/unavailable/uncertain messages, and
429s pause all sends until `retry_after`. Never delete this state to retry a
broadcast. Users who never opened the bot or blocked it may be unreachable.

### Photo posts

Send images **as photos**, not documents, in private chat (individually, forwarded,
or as albums), then send `собери пост`. The bot reuses Telegram file IDs without
downloading the photos. Captions and caption formatting are preserved; no generated
caption is added. Telegram represents an album as grouped messages, not a merged image.
Select the whole album when forwarding it.

The plain command uses only photos not yet successfully assembled. An explicit
`собери пост из последних 3 фото` can also reuse earlier photos. If more than 10 new
photos are waiting, the bot asks for an explicit count; unselected photos remain
pending. A failed send does not clear the selection. Incoming photos after a command
are kept for the next post, even while the first post waits in the media queue.
Up to 50 photos are remembered per chat/sender/topic, across restarts. Older assembled
entries are trimmed first; if all 50 are pending, new photos are refused with a notice.

Time commands select all remembered photos in the requested window, including already
assembled photos. The window ends at the command's Telegram message timestamp, so a
queue delay does not change the result. For forwarded photos, the relevant timestamp
is when they were sent to this chat, not the original post date. "Today" uses a fixed
UTC+3 midnight, independent of the server timezone. More than 10 matching photos causes
a notice instead of silently truncating or creating multiple posts. The 50-photo history
limit still applies. Older stored entries without `sent_at` are not assigned guessed
dates: they remain available through plain and counted commands but not time filters.

In groups, all delivered human photo messages are saved silently, without requiring a
mention in their captions. Mention the bot in the assembly command. Telegram must let
the bot receive ordinary group messages (bot admin or Privacy Mode disabled). The bot
cannot reconstruct previously ignored messages through this polling workflow: resend
missed photos after upgrading. Protected photos and messages from bots are not collected.
Photo history is separate from the existing video history.

### Tests

Run the offline photo workflow tests (standard Ruby libraries only):

```sh
ruby test/photo_posts_test.rb
```

With the application's gems installed, also run the Telegram compatibility test:

```sh
bundle exec ruby test/photo_posts_telegram_smoke.rb
```

It uses real Telegram message types and a stubbed HTTP adapter, with no network
requests or messages to real chats.

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
| `MAX_MEDIA_LINKS_PER_MESSAGE` | `10` | Maximum video links combined into one Telegram media group (capped at 10). |
| `MAX_MEDIA_HISTORY_PER_CHAT` | `50` | Number of bot-sent videos remembered per chat for the “recent videos” command. |
| `MEDIA_QUEUE_SIZE` | `4` | Maximum queued media jobs. |
| `MEDIA_WORKER_COUNT` | `1` | Number of media worker threads, capped at `4`. |
| `YTDLP_MAX_FILESIZE_MB` | `96` | Maximum final media file size sent to Telegram after compression. If public Bot API uploads reject files near this size, lower it or use a local Bot API server. Set `0` to disable the upload size cap. |
| `YTDLP_MAX_DOWNLOAD_FILESIZE_MB` | `150` | Maximum source media file size downloaded before compression. With `ffmpeg`, temporary download directories may use up to twice this size during merges. Set `0` to disable the download size cap. |
| `YTDLP_MAX_DURATION_SECONDS` | `600` | Maximum video duration. Set `0` to disable the duration cap. |
| `YTDLP_PROBE_TIMEOUT_SECONDS` | `20` | Timeout for metadata probing. |
| `YTDLP_DOWNLOAD_TIMEOUT_SECONDS` | `90` | Timeout for media downloads. |
| `YTDLP_SOCKET_TIMEOUT_SECONDS` | `15` | Network socket timeout passed to `yt-dlp`. |
| `FFMPEG_TIMEOUT_SECONDS` | `120` | Timeout for video normalization and compression attempts. |
| `SCREENSHOT_TIMEOUT_SECONDS` | `30` | Timeout for tweet screenshot generation. |
| `TWITTER_SCREENSHOT_PYTHON` | Empty | Optional Python executable path for tweet screenshots, for example `/home/bot/telegram_super_bot/.venv/bin/python`. |
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
