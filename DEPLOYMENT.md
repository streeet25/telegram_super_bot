# Production deployment

The production bot is on `root@2.24.29.59` in the Docker container
`videomorph-production`. The host was supplied by the owner and verified on
2026-11-01: `videomorph.service` is enabled/running and Telegram `getMe` confirms
`VideoMorph_bot`. The active release is described below.

The previous host `root@5.61.91.77` was rechecked on 2026-11-01: its service is
inactive/disabled, with no bot container or `bot.rb` process. Do not start that
retired instance or update its credentials; the active consumer is on `2.24.29.59`.

## Active release — upload size / HTTP 413 protection (2026-11-01)

`videomorph:upload413-20261101`, pinned as
`sha256:13844c562c2199d03a8b52a4ccdbad16a643050e9ab827faccd4e1f0d8c90eea`,
adds source commit `9960c87` on top of the GIF release below. The commit was
pushed before rollout. Dependencies, cookies, environment and all seven state
files were preserved; yt-dlp remains `2026.10.26`.

The public API upload limit now has a safe 49 MiB ceiling, including with the
existing environment value `YTDLP_MAX_FILESIZE_MB=96`. Lower positive limits are
respected. Oversized singles are compressed before upload. A structured Telegram
or HTTP 413 allows exactly one further, smaller encode and upload attempt;
ambiguous timeouts and unrelated errors are never retried. Only confirmed sends
enter history and feed controls. Original and compressed fingerprints remain
available for deduplication. Repeated size rejection returns a plain explanation,
not the raw API error. Albums are not automatically retried or split. GIF manual
publication, privacy choices, clean captions and all earlier behavior are retained.

The candidate passed 204 Ruby tests, 33 Python tests, four native Telegram
serialization smokes and one real yt-dlp/ffmpeg merge smoke without network or
production state. The new smoke uses real multipart serialization, a stubbed 413
response and real ffmpeg to verify a smaller retry, exactly-once history/feed
effects, cleanup and no timeout retry. No Telegram test sends or announcements
were performed.

The reported Instagram reel `De_3fLgR-DS` downloaded successfully as a
7,692,939-byte, 73.794-second, 406×720 H.264/AAC MP4. Its original failed upload
size was not logged; the reported live 413 was not reproduced and its exact
cause remains unconfirmed. A simulated 413 on this downloaded file produced one
3,495,258-byte, 270×480 Telegram-ready retry file. This was a download/compression
check only, not an actual Telegram upload.

Rollout succeeded at `2026-11-01 14:00:38 UTC`. Private pre-release snapshots and
the sanitized result are retained in
`/etc/videomorph/runtime-backups/upload413-20261101T140037Z/`. Post-start `getMe`
confirmed the same bot; the service, workers and feed were healthy, with no startup
or polling-conflict markers and `NRestarts=0`. Runtime source hashes matched the
commit, and the live effective upload cap was verified as 49 MiB. The existing
environment value did not need changing. The temporary test/build directory and
downloaded test media were removed after verification.

Rollback can pin the retained GIF image below and restart through systemd; it
understands the same state schema, so no state migration or snapshot restoration
is needed. That older image does not clamp the legacy 96 MiB setting: explicitly
use `YTDLP_MAX_FILESIZE_MB=49` if rolling back. Do not restore old state over newer
user activity. Older pre-GIF images still require the downgrade precautions below.

## Previous release — Twitter GIF animations (2026-11-01)

`videomorph:twitter-gif-20261101`, pinned as
`sha256:4eecad3fd6a9b8886adca8ee804df253b1ac6499ae8b8258c9c0fa6b6db0002b`,
adds source commit `9846095` on top of the Twitter text-only image below. The
commit was pushed before deployment. Dependencies, environment, credentials and
the existing seven state files were preserved; yt-dlp remains `2026.10.26`.

Twitter's native `animated_gif` media type now survives extraction as a per-entry
marker. The bot sends these silent MP4s through `sendAnimation`, including manual
channel publication by animation file ID. Ordinary unmarked GIFs stay private
until **Опубликовать в Побочку** is pressed, even after general consent or restart.
`+` retains immediate explicit one-off permission; `-` retains exclusion until an
explicit later button click. Mixed batches preserve order, with animations sent
individually and only adjacent ordinary videos grouped into albums. GIF IDs do
not enter video-album history. Deduplication, bans, clean captions and preferences
are unchanged. Follow the GIF downgrade precautions under runtime notes below
before rolling back to a pre-GIF image.

The final candidate passed 195 Ruby tests, 33 Python tests, three native Telegram
serialization smokes (including multipart GIF upload, actual Animation callback
types and anonymous file-ID publication) and the real yt-dlp/ffmpeg merge smoke.
These checks used no external network or production state; no live GIF URL was
provided, and no test messages or announcements were sent to Telegram.

An initial post-start validation assertion triggered a rollback; the exact failed
assertion was not retained. The old service was confirmed healthy before retrying
with environment/mount comparisons independent of enumeration order. Final
rollout succeeded at `2026-11-01 13:27:18 UTC`. Its private backup and sanitized
result are in `/etc/videomorph/runtime-backups/twitter-gif-20261101T132718Z/`.
The earlier attempt's backup `twitter-gif-20261101T132333Z` is also retained.
Post-start `getMe` confirmed the same bot identity; service, worker and feed startup
were healthy, with no startup/polling-conflict markers and `NRestarts=0`. All six
runtime source hashes matched the committed files. No old state was restored.

## Previous release — Twitter text-only posts (2026-11-01)

`videomorph:twitter-text-20261101`, pinned as
`sha256:b392e9028f6bda18e9cc2d494898aa13fa71048cff3c80374204aeca4cea9214`,
adds source commit `be88b38` on top of the retained Instagram anonymous-first
image below. The commit was pushed before rollout. No dependency or environment
changes were made; yt-dlp remains `2026.10.26`.

The Twitter extractor now removes ordinary external-link fallback and article
preview cards from a copy of fetched tweet metadata. Confirmed text/photo-only
posts therefore use the existing silent no-video path, instead of following an
article URL and reporting an extraction error. Native videos/GIFs, player cards,
own-before-quoted ordering, credentials and Twitter extractor arguments are
preserved. API/access failures, timeouts and genuine extraction errors remain
visible. The official version-pinned Twitter source reproduces the article-link
fallback in offline fixtures; the user's exact failing tweet URL was not supplied.

The final candidate passed 184 Ruby tests, 31 Python tests, both native Telegram
serialization smokes and the real yt-dlp/ffmpeg merge smoke, without network or
production state. The Twitter CLI test verifies actual plugin selection, not
`--list-extractors` (which exits before plugin loading in this yt-dlp version).

The launcher digest was replaced atomically after stopping the old service.
Seven state files, environment, cookies, container user and mounts were preserved.
The private pre-release backup is
`/etc/videomorph/runtime-backups/twitter-text-20261101T123018Z`.
After restart, `getMe` confirmed `VideoMorph_bot`; the service, media workers and
feed were ready, with no startup/polling-conflict markers. Runtime source hashes
matched the committed files. No Telegram test sends or announcements were made.
Rollback targets the retained Instagram image below; do not restore old state
over newer user activity. The temporary build directory was removed; the private
backup and previous release image remain available.

## Previous release — Instagram anonymous-first (2026-11-01)

`videomorph:instagram-anonymous-20261101`, pinned as
`sha256:c1992410029366016bf8f915d9c4282d26c7a1dc2e0c2f9b5f915ce155701a91`,
contains source commit `fd862cf`, the previously prepared format-selector fix,
and `yt-dlp[default]==2026.10.26`. The source commit was pushed before rollout.
The complete offline suite passed: 179 Ruby tests, 18 Python tests, two native
Telegram serialization smokes, and the real yt-dlp/ffmpeg merge smoke.

Instagram now attempts extraction/download without account cookies and without
external yt-dlp configuration, then retries once with configured cookies on an
extraction failure. Successful public downloads never open the cookie jar. Safety
stops (timeouts, duration/size limits including yt-dlp's successful filesize skip)
and confirmed posts without video do not retry. A known audience restriction
survives an uninformative authenticated HTTP 400. `media_errors.rb` must be included
alongside `config.rb` and `ytdlp.rb`; other providers still catch the same base
error types. No state schema, publication policy, credentials or account settings
were changed; no announcements or test Telegram sends were performed.

The launcher was switched atomically after stopping the old container. The seven
state files, environment and cookie file were preserved; environment, mounts and
Telegram identity were checked after restart. The root-only pre-release backup is
`/etc/videomorph/runtime-backups/instagram-anonymous-20261101T120756Z`.
For rollback, pin the retained clean-caption image below and restart through
systemd; do not restore old state over newer user activity.

Live download-only checks in the candidate succeeded anonymously for
`De6RRGNtKMa` (12 seconds, 1440x2560, 9,924,285 bytes) and `Db8NHvWo46E`
(41 seconds, 1080x1920, 20,779,050 bytes). `DaDAth8giB6` remained audience-restricted
after both public and authenticated attempts; this is reported clearly, not
claimed fixed. Cookie-copy hashes were unchanged for anonymous successes.
After rollout, the exact `De6RRGNtKMa/?vrfl=...` link was also downloaded through
the running production image: 12 seconds, 1440x2560, Telegram-ready MP4, no
authenticated retry and no cookie-copy changes. The service and workers were
ready, the feed initialized successfully, and no startup/polling-conflict markers
were present. The temporary build directory was removed; both release images and
the private rollback backup remain.

## Format-fix preparation history

On 2026-10-27, an offline candidate was built on the old host `5.61.91.77` as
`videomorph:formats-ytdlp20261026-candidate-20261027`, digest
`sha256:426fa440f1da722384b4859fd89ba98aed4cbf3b5039964511b04a5ec0b1318f`.
It contains the shared format-selector fix and
[`yt-dlp[default]==2026.10.26`](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26),
upgraded from 2026.08.19; the image still runs as `10001:10001`.
The complete offline suite passed against both yt-dlp versions: 162 Ruby tests,
18 Python tests, two native Telegram serialization smokes and one real
yt-dlp/ffmpeg merge smoke, all without network access or production state.

The regression reproduces failure of the old selectors when only separate video
and audio tracks exist. The corrected selectors merge both into MP4 and reject
audio-only formats, following the official
[format-selection rules](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/README.md#format-selection).
The user's specific URL for the 2026-10-27 format error has not been supplied or
verified. That preparation did not change any live service, launcher, cookies or
state. Its selector fix and yt-dlp update are now included in the active release
above. Do not replace the active image with this older candidate, which lacks the
anonymous-first behavior.

## Verified active runtime

- Application code inside the container: `/opt/app`
- Persistent bot state: `/var/lib/videomorph` on the host, mounted at the same path
- Cookies file: `/etc/videomorph/cookies/cookies.txt` on the host, available at `/run/videomorph/cookies.txt` inside the container
- The cookies directory is mounted read-write because yt-dlp updates its cookie jar. Keep the file mode `0600`, owned by the container user `10001:10001`.
- Supervisor: `videomorph.service`, which runs `/usr/local/libexec/videomorph-run.py`
- The launcher pins the active image by digest, as recorded above. The preceding `videomorph:twitter-gif-20261101` image supports the current state schema; see its upload-cap rollback note above. The older `videomorph:twitter-text-20261101` (`sha256:b392e9028f6bda18e9cc2d494898aa13fa71048cff3c80374204aeca4cea9214`) and Instagram/clean-caption images also remain. They do not support animation publication: follow the GIF downgrade precautions below before using them. Pre-button images additionally require the unpublished-control migration.

The clean-caption release no longer appends publication status to video captions,
including after publication, cancellation, consent or a duplicate result. Controls
and callback feedback remain; album status stays in separate reply messages.
Telegram's HTTP 400 "message is not modified" during refresh is a harmless no-op;
other UI failures remain logged. Existing captions are cleaned only when their
controls are refreshed, with no startup history sweep, data migration or broadcast.

The bundled directory `/opt/app/ytdlp_plugins/videomorph/yt_dlp_plugins/extractor/`
contains `videomorph_threads.py` and `videomorph_twitter.py`. Preserve it in the
image, not just Ruby files. Threads and Twitter calls explicitly enable it through
`--plugin-dirs`; each plugin only matches its own provider. Threads uses public
preview data without the Instagram cookie jar. Twitter preserves its existing
cookies and `--extractor-args twitter:...` settings, while skipping text/article
links instead of attempting to download an unrelated external page. Real access
and network failures remain visible. Verify with `/opt/venv/bin/python
/opt/app/test/threads_extractor_test.py` and `twitter_extractor_test.py` (the system
Python does not include yt-dlp), the Ruby tests and both Telegram smoke tests.
The supplied `katia_lok/DeWshaKHBhY` post downloaded as a 12-second 720×1280 MP4
in the candidate without Telegram sends. No data migration or announcement is
part of this release; preserve all existing state, privacy settings and receipts.

Once the active production host and polling ownership are confirmed, use
`systemctl restart videomorph.service` to restart production. Do not manage the
container lifecycle directly: the launcher uses `docker run --rm`, and systemd
may recreate a stopped container. Changes copied into a running container are not
persistent; deploy a validated image and update the launcher's pinned digest.

Twitter GIF support adds optional `media_type: "animation"` to feed control jobs;
missing `media_type` still means video. Keep this field across restarts so queued
manual GIF publications use `sendAnimation`, not `sendVideo`. Unmarked animations
stay `awaiting_choice` with no general-consent link or automatic timer. For a
rollback to a pre-GIF image, stop the service, privately back up state, cancel
unfinished animation jobs and expire their controls before restarting: the old
publisher cannot send animation file IDs correctly, and its old controls must
not re-queue them. Preserve all already-published history and other jobs. Never
replace current state with an older snapshot to perform this downgrade.

Photo-post state is saved as `/var/lib/videomorph/photo_history.json` (mode `0600`)
when the first photo is received. Preserve this file alongside the existing runtime
state when deploying. It contains private Telegram file IDs and captions, not image
downloads. Never put runtime state into an image or a Git commit.

The anonymous feed is enabled with `VIDEO_FEED_CHANNEL=@pobo4ka_ink` in
`/etc/videomorph/environment`. It covers new successful group downloads and
private-chat downloads only after that user's consent. `/privacy` disables all
of a user's publications until they opt back in. Keep `/var/lib/videomorph/video_feed.json`
(mode `0600`, owner `10001:10001`) in private state backups: it contains the durable
queue, deduplication keys, moderation mapping, bans and privacy choices. Never
reset it on restart. The startup line `Video feed enabled:` confirms initialization;
`Video feed disabled:` means fail-closed initialization and requires investigation.
Do not call `getUpdates` alongside production, and do not seed the feed from old
media history. Validate serialization with offline smoke tests; channel rights
can be checked read-only. Changes to the public channel need scoped authorization.

Deduplication aliases and the `duplicates_skipped` counter live in `video_feed.json`.
Keep the existing file on rollout: its published-video keys are the baseline for
future duplicate suppression. The publisher rechecks queued items against known
aliases immediately before sending. This update does not delete existing posts.
Visual signatures are optional, versioned fields in the same jobs; older state
remains compatible. The visual index is built from newly delivered media, with
no historical download/backfill. On an authorized exact repeat, an old record
without a signature can be enriched. Retain original exemplars and all privacy
choices/bans. Run `ruby test/video_fingerprint_test.rb` in the candidate image;
it generates local fixtures and tests re-encoding, resizing and edge cropping.
It requires the existing ffmpeg/ffprobe, not network access or new packages.

First-link consent requests are stored in the same state file and include a
submitter-bound token with a 24-hour expiry. Successfully delivered initial
videos wait as `awaiting_consent`; approval of their specific prompt releases
them without re-downloading. Existing preferences/bans and generic old buttons
retain their meaning. The rollout does not recover or republish videos discarded
by the previous version; affected users can resubmit their original link once.

Per-link `+` permissions persist as `one_off` with a privacy revision; an absent
field preserves the old default behavior. `-` items have no feed context and are
never queued. A new explicit global off revokes pending one-off permissions,
even when the default was already off. No deployment changes existing choices.

Per-video button records use optional `control_*` fields on feed jobs. Unmarked
auto-publications start their 30-second window only after control attachment is
confirmed; `control_ready: false` fails closed after an interrupted attachment.
Preserve all fields on restart. `awaiting_choice` records are private, expire in
24 hours and are excluded from public deduplication. Existing state/history is
not backfilled. No announcement command is part of this release or its startup.
For rollback to a pre-button image, stop the service and conservatively change
unpublished control jobs (`queued`, `failed`, `awaiting_consent`, `awaiting_choice`)
to `opted_out` before starting the old image: it does not understand the new
attachment gate. Keep sent/uncertain history, preferences, bans and receipts.

The user-authorized private link-control announcement is an explicit maintenance
command, not part of startup: from `/var/lib/videomorph`, run
`bundle _2.6.7_ exec ruby /opt/app/scripts/announce_link_controls.rb` for a read-only
recipient-count preview, adding `--send` only to send the approved update.
Preserve `/var/lib/videomorph/link_controls_announcement.json` (0600, 10001:10001)
alongside other private state backups; it prevents duplicate announcements.
Interrupted/ambiguous deliveries are not automatically retried. It never sends
to groups or the feed channel and does not alter user privacy preferences.

New photo entries include the original Telegram message timestamp (`sent_at`, Unix
seconds). Existing undated entries are preserved without guessing their dates; use
plain/count commands for them. "Today" uses UTC+3, regardless of the host timezone.
Group photos are now collected without a mention when Telegram delivers them. Photos
ignored by an older version must be resent; changing the image does not replay history.

For cookie updates, stop the service first, back up the cookie jar outside the
mounted directory with root-only access, replace only the requested provider's
cookies, and preserve other providers' entries. Replace the file atomically in
the same directory with the permissions above, then start the service. Instagram
cookie backups are stored in `/etc/videomorph/cookie-backups` on the host. Verify
an actual download through the application's downloader, without sending test
messages to user chats.

The 2026-11-01 Instagram cookie rotation was applied on `2.24.29.59`: eight new
Instagram cookies (including `sessionid`) replaced six old Instagram entries;
all 101 non-Instagram cookie rows were preserved byte-for-byte during the update.
The runtime file remains `0600`, owned by `10001:10001`. The root-only backup is
`/etc/videomorph/cookie-backups/cookies-before-instagram-20261031T222522Z-a24322.txt`
(the filename uses UTC). The service was stopped only for the atomic replacement
and then started; `getMe` and active/running status were verified. No code/image,
feed preferences, or state were changed, and temporary credential copies were
removed locally and remotely.

A download-only verification through the running image's Ruby downloader, using
a private temporary cookie copy, succeeded for Instagram `Db8NHvWo46E`: 41 seconds,
720x1280, 7,690,375 bytes, Telegram-ready MP4. No Telegram messages were sent.
The older `DecRcFkx6hh` link still returned HTTP 400 during metadata extraction;
that individual link is not claimed fixed by this credential update.

Never store the bot token, API credentials, or cookies in this repository. Preserve the
container environment and both mounts whenever replacing the production container.
