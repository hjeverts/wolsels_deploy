# Wolsels deploy

Docker Compose configuration for Wolsels: keeping track of wool stock, blends, spinning results and the
production of raw wool by your own animals. With accounts (everyone has their own data) and two-step
verification.

| Repo                                                                 | Content                                  |
|----------------------------------------------------------------------|------------------------------------------|
| [wolsels_backend](https://github.com/hjeverts/wolsels_backend)       | ASP.NET Core API + SQLite                |
| [wolsels_frontend](https://github.com/hjeverts/wolsels_frontend)     | Angular app, served by nginx             |
| wolsels_deploy (this one)                                            | Docker Compose, nginx site, backups      |

## Installation

Required on the server: Docker (with Compose) and nginx. Node or .NET are not needed: the images are built
by GitHub Actions and pulled from ghcr.io (see [Images](#images)).

```sh
git clone https://github.com/hjeverts/wolsels_deploy.git

cd wolsels_deploy
cp .env.example .env && chmod 600 .env
nano .env                                    # e.g. WOLSELS_PORT, WOLSELS_PUBLIC_URL, mail server
docker compose up -d                         # Wolsels on 127.0.0.1:<WOLSELS_PORT>

sudo cp nginx/wolsels.conf /etc/nginx/sites-available/wolsels   # check the port in proxy_pass
sudo ln -s /etc/nginx/sites-available/wolsels /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d wolsels.example.nl    # HTTPS
```

After certbot, enable the `Strict-Transport-Security` line in the site. Always use HTTPS: the session cookie
is then sent as `Secure`.

Then create your own account right away: the **first account** becomes administrator and takes over any data
from before accounts were introduced. Afterwards set `ALLOW_REGISTRATION=false` in `.env` if others may not
sign up themselves (and run `docker compose up -d`); someone can then still create an account via a household
invitation link.

## Households and administration

- **Household:** data belongs to a household. Invite your partner via *Household → Create invitation link*
  and send the link yourself; you then see and edit the same data, each with your own login and 2FA.
  Someone can be a member of several households and switches at the top.
- **Administrator:** the first account (in existing installations: the creator of the first household).
  Under *User management*: block accounts, reset 2FA, create a reset link for a new password, appoint
  administrators and delete accounts. Administrators don't see household data.
- **Locked out?** Set `ADMIN_EMAIL=your@address.com` in `.env` and run `docker compose up -d`: that account
  becomes administrator at startup.

Which port is free? `ss -tln | grep -q ':8083 ' && echo taken || echo free`

## Stock photos (backend and frontend from v1.1.0)

To upload photos the nginx on the server must allow larger requests (4 MB instead of 1 MB). Don't copy
`nginx/wolsels.conf` again for this: certbot has modified the site on the server for HTTPS. Only change that
one line:

```sh
sudo sed -i 's/client_max_body_size 1m;/client_max_body_size 4m;/' /etc/nginx/sites-available/wolsels
sudo nginx -t && sudo systemctl reload nginx
```

Without this change larger photos fail with a message that the file is too large to upload (HTTP 413).
Photos are stored in the database and are therefore included in the backups.

## Switching to images from ghcr.io

Did you build the images on the server until now? Then change the image settings in `.env`:

```sh
REGISTRY=ghcr.io/hjeverts       # was: wolsels
TAG=latest
# BACKEND_CONTEXT and FRONTEND_CONTEXT can be removed
```

Do this before the first `./scripts/update.sh` with the new version; with `REGISTRY=wolsels` the script would
try to pull images from Docker Hub. Then run:

```sh
git pull --ff-only
./scripts/update.sh --force
```

The directories `../wolsels_backend` and `../wolsels_frontend` are no longer needed afterwards. Your data in
the volume stays where it is.

## Switching from the version without a frontend container

Did you install Wolsels earlier with `deploy-frontend.sh` and `/var/www/wolsels`? Your data is in the Docker
volume `wolsels_wolsels-data` and stays there during the switch.

```sh
cd wolsels_deploy
./scripts/backup.sh                          # to be safe
git pull --ff-only
docker compose up -d --remove-orphans
```

First update `.env` as described under [Switching to images from ghcr.io](#switching-to-images-from-ghcrio).

Your existing `WOLSELS_API_PORT` in `.env` is used as the port automatically (renaming it to `WOLSELS_PORT`
is fine). Then replace the nginx site with the new, simpler version; certbot adapts it for HTTPS again:

```sh
sudo cp nginx/wolsels.conf /etc/nginx/sites-available/wolsels   # check the port in proxy_pass
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d wolsels.example.nl
```

`/var/www/wolsels` is no longer needed afterwards (`sudo rm -r /var/www/wolsels`).

## Architecture

```
browser ──► nginx on the server (TLS, nginx/wolsels.conf)
              └── everything ──► frontend container (nginx, 127.0.0.1:<WOLSELS_PORT>)
                                   ├── /       Angular app
                                   └── /api/ ──► backend container ──► SQLite + keys (volume wolsels-data)
```

- The nginx on the server only does TLS and a single `proxy_pass`, and passes on the visitor's real IP
  (the attempt limits work per IP).
- The frontend container serves the app, forwards `/api/` to the backend and sets the security headers.
  It only takes the client IP from proxies on internal networks.
- The backend is only reachable through the frontend container. The database is created and migrated
  automatically at startup.
- Both containers run as a non-root user and have a health check.

## Configuration (`.env`)

| Variable                            | Default                 | Description                                          |
|-------------------------------------|-------------------------|------------------------------------------------------|
| `WOLSELS_PUBLIC_URL`                | –                       | Public URL (for links in emails)                     |
| `WOLSELS_PORT`                      | `8080`                  | Port on 127.0.0.1 (= `proxy_pass` in the nginx site) |
| `MAX_BLEND_COMPONENTS`              | `6`                     | Maximum number of wools per blend                    |
| `ALLOW_REGISTRATION`                | `true`                  | Allow self sign-up (the first account and invitations always work) |
| `ADMIN_EMAIL`                       | –                       | This account always becomes administrator (recovery) |
| `LOGIN_MAX_FAILED_ATTEMPTS`         | `5`                     | Failed attempts before an account is locked          |
| `LOGIN_LOCKOUT_MINUTES`             | `15`                    | Duration of that lockout                             |
| `AUTH_RATE_LIMIT_PER_MINUTE`        | `10`                    | Max. login/sign-up/2FA attempts per IP per minute    |
| `AUTH_RATE_LIMIT_PER_HOUR`          | `60`                    | Same per hour                                        |
| `PASSWORD_RESET_PER_IP_PER_HOUR`    | `5`                     | Max. reset mail requests per IP per hour             |
| `PASSWORD_RESET_PER_EMAIL_PER_HOUR` | `3`                     | Max. reset mails per email address per hour          |
| `SMTP_HOST`                         | –                       | Mail server; empty = no "forgot password"            |
| `SMTP_PORT` / `SMTP_SECURITY`       | `587` / `Auto`          | `StartTls` (587), `SslOnConnect` (465) or `None`     |
| `SMTP_USERNAME` / `SMTP_PASSWORD`   | –                       | Mail server credentials                              |
| `SMTP_FROM` / `SMTP_FROM_NAME`      | – / `Wolsels`           | Sender                                               |
| `REGISTRY` / `TAG`                  | `ghcr.io/hjeverts` / `latest` | Registry and tag of the images                 |
| `BACKEND_TAG` / `FRONTEND_TAG`      | `TAG`                   | Fixed version per image, e.g. `1.2.0`                |
| `COMPOSE_FILE`                      | –                       | With `docker-compose.build.yml` added: build yourself |
| `BACKEND_CONTEXT`                   | `../wolsels_backend`    | Backend build context when building yourself (path or git URL) |
| `FRONTEND_CONTEXT`                  | `../wolsels_frontend`   | Frontend build context when building yourself        |

After changing `.env`: `docker compose up -d`. If you change `WOLSELS_PORT`, also change `proxy_pass` in the
nginx site.

## Images

[wolsels_backend](https://github.com/hjeverts/wolsels_backend) and
[wolsels_frontend](https://github.com/hjeverts/wolsels_frontend) each have their own version numbers.
An image is only built when you create a version tag in that repo; merging to `main` only runs the tests.
That way you can collect several changes and release them together.

```sh
cd wolsels_backend                            # only the repo(s) that changed
git switch main && git pull
git tag v1.2.0 && git push origin v1.2.0      # or via GitHub: Releases → Draft a new release
```

After a few minutes the image is on ghcr.io; then run `./scripts/update.sh` on the server.
Use [semver](https://semver.org/): `v1.2.1` for a bug fix, `v1.3.0` for a new feature. If the frontend needs a
new backend feature, release the backend first.

| Image                                 | Tags                                                     |
|---------------------------------------|----------------------------------------------------------|
| `ghcr.io/hjeverts/wolsels-backend`    | `1.2.0`, `1.2` and `latest` (the newest version)         |
| `ghcr.io/hjeverts/wolsels-frontend`   | the same, with its own version numbers                   |

Every Monday the newest version is rebuilt without cache, so that security updates of the base images are
picked up; `./scripts/update.sh` fetches them automatically.

**A fixed or earlier version:** set `BACKEND_TAG=1.1.0` and/or `FRONTEND_TAG=1.0.0` in `.env` (the versions
are listed with the packages on GitHub) and run `./scripts/update.sh`. Remove the line to follow `latest`
again. Note: an older backend doesn't know newer database migrations; if needed, also restore the backup from
before the update.

**Building yourself** instead of using ghcr.io (e.g. for your own changes): clone `wolsels_backend` and
`wolsels_frontend` next to this repo and set in `.env`:

```sh
COMPOSE_FILE=docker-compose.yml:docker-compose.build.yml
REGISTRY=wolsels
```

`./scripts/update.sh` then runs `git pull` in the source repos and builds the images on the server.

## Security

- **Accounts:** passwords of at least 10 characters, securely hashed (ASP.NET Core Identity).
  Every user only sees their own data.
- **Two-step verification:** set up under *Account* with an authenticator app (TOTP), including single-use
  recovery codes.
- **Limited attempts:** after 5 wrong passwords or 2FA codes an account is locked for 15 minutes; in addition
  there is a limit per IP address per minute and per hour, and for reset mails also per email address.
- **Session:** HttpOnly cookie with SameSite=Strict, `Secure` over HTTPS. The keys are stored in the volume,
  so that a restart logs nobody out.
- **Headers:** Content-Security-Policy, X-Frame-Options, nosniff and Referrer-Policy via the frontend container.
- **Containers:** run as a non-root user; only the frontend is reachable, and only via 127.0.0.1.

## Maintenance

```sh
docker compose logs -f backend      # logs
./scripts/update.sh                 # update: pull new images, backup, restart
./scripts/backup.sh                 # back up the database to ./backups
```

`backup.sh` stops the backend for a few seconds so that the database is fully written, and keeps the newest
10 backups (`BACKUP_KEEP=20 ./scripts/backup.sh` for more). `update.sh` makes a backup automatically before
every update. Copy `backups/` to another place regularly.

`update.sh` updates this repo and then fetches the newest images (when building yourself: the source repos),
and shows which versions are new. If there is nothing new it stops (`--force` to restart the containers
anyway, or to rebuild when building yourself). Then it waits until both containers are healthy and otherwise
shows the logs. The data in the volume always stays during updates; never use `docker compose down -v`,
because `-v` removes the volume with all data.

Restoring a backup:

```sh
docker compose stop backend
docker compose run --rm --no-deps --user root -v "$PWD/backups:/backups" --entrypoint sh backend \
  -c 'cp /backups/<file>.db /data/wolsels.db && rm -f /data/wolsels.db-wal /data/wolsels.db-shm && chown $APP_UID /data/wolsels.db'
docker compose start backend
```

A backup contains the database (with all accounts), not the session cookie keys; after restoring, everyone
at most has to log in again.

## License

[MIT](LICENSE) © 2026 Hans Everts
