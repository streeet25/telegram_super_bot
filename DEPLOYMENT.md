# Production deployment

The production bot runs on `root@5.61.91.77` in the Docker container
`videomorph-production`.

- Application code inside the container: `/opt/app`
- Persistent bot state: `/var/lib/videomorph` on the host, mounted at the same path
- Cookies file: `/etc/videomorph/cookies/cookies.txt` on the host, available at `/run/videomorph/cookies.txt` inside the container
- The cookies directory is mounted read-write because yt-dlp updates its cookie jar. Keep the file mode `0600`, owned by the container user `10001:10001`.
- Supervisor: `videomorph.service`, which runs `/usr/local/libexec/videomorph-run.py`
- The launcher pins the Docker image by digest. The photo-post release validated on 2026-10-07 is `videomorph:photo-posts-20261007` (`sha256:84d4ae90959d95573de82f04925415493a480f498ecf5dec03bc7830c90f00f5`). The previous image `videomorph:4c4d242` is retained for rollback.

Use `systemctl restart videomorph.service` to restart production. Do not manage the
container lifecycle directly: the launcher uses `docker run --rm`, and systemd
may recreate a stopped container. Changes copied into a running container are not
persistent; deploy a validated image and update the launcher's pinned digest.

Photo-post state is saved as `/var/lib/videomorph/photo_history.json` (mode `0600`)
when the first photo is received. Preserve this file alongside the existing runtime
state when deploying. It contains private Telegram file IDs and captions, not image
downloads. Never put runtime state into an image or a Git commit.

For cookie updates, stop the service first, back up the cookie jar outside the
mounted directory with root-only access, replace only the requested provider's
cookies, and preserve other providers' entries. Replace the file atomically in
the same directory with the permissions above, then start the service. Instagram
cookie backups are stored in `/etc/videomorph/cookie-backups` on the host. Verify
an actual download through the application's downloader, without sending test
messages to user chats.

Never store the bot token, API credentials, or cookies in this repository. Preserve the
container environment and both mounts whenever replacing the production container.
