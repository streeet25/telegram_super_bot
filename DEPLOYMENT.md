# Production deployment

The production bot runs on `root@5.61.91.77` in the Docker container
`videomorph-production`.

- Application code inside the container: `/opt/app`
- Persistent bot state: `/var/lib/videomorph` on the host, mounted at the same path
- Cookies file: `/etc/videomorph/cookies/cookies.txt` on the host, mounted read-only at `/run/videomorph/cookies/cookies.txt`

Never store the bot token, API credentials, or cookies in this repository. Preserve the
container environment and both mounts whenever replacing the production container.
