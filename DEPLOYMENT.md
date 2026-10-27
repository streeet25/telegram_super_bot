# Production deployment

The last validated production deployment was on `root@5.61.91.77` in the Docker
container `videomorph-production`.

**Status checked 2026-10-27:** `videomorph.service` is inactive and disabled on
that host, the production container is absent, and no recent service logs were
available. The current live bot's host is unconfirmed. Do not start this old
service until the active deployment and polling ownership are established.
The paths and release information below describe the last validated deployment,
not confirmation that the bot is currently running there.

## Prepared format fix — not deployed

On 2026-10-27, an offline candidate was built on that host as
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
The user's specific failing URL has not been supplied or verified. No live
service, launcher, cookies or state were changed. Confirm the active host and
download that URL without Telegram sends before rolling out this candidate.

## Last validated runtime

- Application code inside the container: `/opt/app`
- Persistent bot state: `/var/lib/videomorph` on the host, mounted at the same path
- Cookies file: `/etc/videomorph/cookies/cookies.txt` on the host, available at `/run/videomorph/cookies.txt` inside the container
- The cookies directory is mounted read-write because yt-dlp updates its cookie jar. Keep the file mode `0600`, owned by the container user `10001:10001`.
- Supervisor: `videomorph.service`, which runs `/usr/local/libexec/videomorph-run.py`
- The launcher pins the Docker image by digest. The clean-caption release validated on 2026-10-16 is `videomorph:clean-captions-20261016` (`sha256:81e746593e05947612c1dcefd0a619baed0a6335372c445c1f2c47968d81efbe`). The previous image `videomorph:threads-20261012` (`sha256:3dd364279f2704e8c6f2c3e61401a449652774b995f8f4bc30b670476d25ba97`) is retained for rollback. Both understand the current button state; see the unpublished-control migration below before starting an older pre-button image.

The clean-caption release no longer appends publication status to video captions,
including after publication, cancellation, consent or a duplicate result. Controls
and callback feedback remain; album status stays in separate reply messages.
Telegram's HTTP 400 "message is not modified" during refresh is a harmless no-op;
other UI failures remain logged. Existing captions are cleaned only when their
controls are refreshed, with no startup history sweep, data migration or broadcast.

The Threads release adds `/opt/app/ytdlp_plugins/videomorph/yt_dlp_plugins/extractor/videomorph_threads.py`.
Preserve this directory in the image, not just Ruby files. Only Threads calls enable
it through `--plugin-dirs`; other providers keep their existing extractor/cookie
behavior. It uses public preview data without the Instagram cookie jar. Verify
with `/opt/venv/bin/python /opt/app/test/threads_extractor_test.py` (the system
Python does not include yt-dlp), the Ruby tests and both Telegram smoke tests.
The supplied `katia_lok/DeWshaKHBhY` post downloaded as a 12-second 720×1280 MP4
in the candidate without Telegram sends. No data migration or announcement is
part of this release; preserve all existing state, privacy settings and receipts.

Once the active production host and polling ownership are confirmed, use
`systemctl restart videomorph.service` to restart production. Do not manage the
container lifecycle directly: the launcher uses `docker run --rm`, and systemd
may recreate a stopped container. Changes copied into a running container are not
persistent; deploy a validated image and update the launcher's pinned digest.

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

Never store the bot token, API credentials, or cookies in this repository. Preserve the
container environment and both mounts whenever replacing the production container.
