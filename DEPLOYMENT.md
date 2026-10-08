# Production deployment

The production bot runs on `root@5.61.91.77` in the Docker container
`videomorph-production`.

- Application code inside the container: `/opt/app`
- Persistent bot state: `/var/lib/videomorph` on the host, mounted at the same path
- Cookies file: `/etc/videomorph/cookies/cookies.txt` on the host, available at `/run/videomorph/cookies.txt` inside the container
- The cookies directory is mounted read-write because yt-dlp updates its cookie jar. Keep the file mode `0600`, owned by the container user `10001:10001`.
- Supervisor: `videomorph.service`, which runs `/usr/local/libexec/videomorph-run.py`
- The launcher pins the Docker image by digest. The anonymous-feed/privacy release validated on 2026-10-08 is `videomorph:pobochka-20261008` (`sha256:dfe1858855eddeee301989feb1544826d3c8e1bc10c286254f6db8cf1fac4402`). The previous image `videomorph:photo-periods-20261007` (`sha256:3f0b242effd1ee64160ab591380cbe9b9e8fcbd92ccc10fbb0a81e3c649b0cc6`) is retained for rollback.

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
