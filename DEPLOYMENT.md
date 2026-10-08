# Production deployment

The production bot runs on `root@5.61.91.77` in the Docker container
`videomorph-production`.

- Application code inside the container: `/opt/app`
- Persistent bot state: `/var/lib/videomorph` on the host, mounted at the same path
- Cookies file: `/etc/videomorph/cookies/cookies.txt` on the host, available at `/run/videomorph/cookies.txt` inside the container
- The cookies directory is mounted read-write because yt-dlp updates its cookie jar. Keep the file mode `0600`, owned by the container user `10001:10001`.
- Supervisor: `videomorph.service`, which runs `/usr/local/libexec/videomorph-run.py`
- The launcher pins the Docker image by digest. The deduplication release validated on 2026-10-08 is `videomorph:dedup-20261008` (`sha256:913eeb1242b2acd0e0c2189046e2ffa6e6f92a14842e9926d1a4c0df9f0b3809`). The previous image `videomorph:first-consent-20261008` (`sha256:d2db97d32a6119ecd1995b4230f088411f12dc5fa184dde7e62d022b2a47d48e`) is retained for rollback.

Use `systemctl restart videomorph.service` to restart production. Do not manage the
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

First-link consent requests are stored in the same state file and include a
submitter-bound token with a 24-hour expiry. Successfully delivered initial
videos wait as `awaiting_consent`; approval of their specific prompt releases
them without re-downloading. Existing preferences/bans and generic old buttons
retain their meaning. The rollout does not recover or republish videos discarded
by the previous version; affected users can resubmit their original link once.

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
