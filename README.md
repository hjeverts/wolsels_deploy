# Wolsels deploy

Docker Compose-configuratie voor Wolsels: bijhouden van wolvoorraad, mengsels, spinresultaten en de
productie van ruwe wol door eigen dieren. Met accounts (ieder zijn eigen gegevens) en
tweestapsverificatie.

| Repo                                                                 | Inhoud                                   |
|----------------------------------------------------------------------|------------------------------------------|
| [wolsels_backend](https://github.com/hjeverts/wolsels_backend)       | ASP.NET Core API + SQLite                |
| [wolsels_frontend](https://github.com/hjeverts/wolsels_frontend)     | Angular-app, geserveerd door nginx       |
| wolsels_deploy (deze)                                                | Docker Compose, nginx-site, backups      |

## Installeren

Nodig op de server: Docker (met Compose) en nginx. Node of .NET zijn niet nodig; alles wordt in
Docker gebouwd.

```sh
git clone git@github.com:hjeverts/wolsels_backend.git
git clone git@github.com:hjeverts/wolsels_frontend.git
git clone git@github.com:hjeverts/wolsels_deploy.git

cd wolsels_deploy
cp .env.example .env && chmod 600 .env
nano .env                                    # o.a. WOLSELS_PUBLIC_URL en eventueel de mailserver

docker compose up -d --build                 # backend op 127.0.0.1:5080

sudo mkdir -p /var/www/wolsels && sudo chown "$USER" /var/www/wolsels   # eenmalig
./scripts/deploy-frontend.sh                 # frontend naar /var/www/wolsels/current

sudo cp nginx/wolsels.conf /etc/nginx/sites-available/wolsels
sudo ln -s /etc/nginx/sites-available/wolsels /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d wolsels.streve.nl    # HTTPS
```

Zet na certbot de `Strict-Transport-Security`-regel in de site aan. Gebruik altijd HTTPS: de
sessiecookie wordt dan als `Secure` verstuurd.

Maak daarna direct je eigen account aan: het **eerste account** neemt eventuele gegevens van
vóór de invoering van accounts over. Zet daarna in `.env` `ALLOW_REGISTRATION=false` als
anderen zich niet zelf mogen aanmelden (en `docker compose up -d`).

## Architectuur

```
browser ──► nginx op de server (TLS, nginx/wolsels.conf)
              ├── /        statische Angular-app uit /var/www/wolsels/current
              └── /api/ ─► backend-container (127.0.0.1:5080) ──► SQLite + sleutels (volume wolsels-data)
```

- **`nginx/wolsels.conf`** serveert de app (met fallback naar `index.html` voor Angular-routes), stuurt
  `/api/` door naar de backend en zet de beveiligingsheaders (Content-Security-Policy e.d.). Hij geeft
  het echte IP van de bezoeker door, waar de pogingslimieten van de backend op werken.
- **`scripts/deploy-frontend.sh`** bouwt de frontend in Docker en zet hem in een nieuwe map onder
  `releases/`; daarna wordt de symlink `current` in één keer omgezet. Er blijven 3 versies bewaard.
  Terugdraaien: `ln -sfn /var/www/wolsels/releases/<vorige> /var/www/wolsels/current`.
- De backend is alleen vanaf de server zelf bereikbaar. De database wordt bij het opstarten
  automatisch aangemaakt en gemigreerd.

## Configuratie (`.env`)

| Variabele                           | Standaard               | Omschrijving                                         |
|-------------------------------------|-------------------------|------------------------------------------------------|
| `WOLSELS_PUBLIC_URL`                | –                       | Openbare URL (voor links in e-mails)                 |
| `WOLSELS_API_PORT`                  | `5080`                  | Poort van de backend op 127.0.0.1 (= `proxy_pass`)   |
| `WOLSELS_WEB_ROOT`                  | `/var/www/wolsels`      | Map voor de frontend (= `root` in de nginx-site)     |
| `MAX_BLEND_COMPONENTS`              | `6`                     | Maximaal aantal soorten wol per mengsel              |
| `ALLOW_REGISTRATION`                | `true`                  | Zelf registreren toestaan (eerste account mag altijd)|
| `LOGIN_MAX_FAILED_ATTEMPTS`         | `5`                     | Foute pogingen voordat een account geblokkeerd wordt |
| `LOGIN_LOCKOUT_MINUTES`             | `15`                    | Duur van die blokkering                              |
| `AUTH_RATE_LIMIT_PER_MINUTE`        | `10`                    | Max. inlog-/registratie-/2FA-pogingen per IP/minuut  |
| `AUTH_RATE_LIMIT_PER_HOUR`          | `60`                    | Idem per uur                                         |
| `PASSWORD_RESET_PER_IP_PER_HOUR`    | `5`                     | Max. aanvragen herstelmail per IP per uur            |
| `PASSWORD_RESET_PER_EMAIL_PER_HOUR` | `3`                     | Max. herstelmails per e-mailadres per uur            |
| `SMTP_HOST`                         | –                       | Mailserver; leeg = geen "wachtwoord vergeten"        |
| `SMTP_PORT` / `SMTP_SECURITY`       | `587` / `Auto`          | `StartTls` (587), `SslOnConnect` (465) of `None`     |
| `SMTP_USERNAME` / `SMTP_PASSWORD`   | –                       | Inloggegevens mailserver                             |
| `SMTP_FROM` / `SMTP_FROM_NAME`      | – / `Wolsels`           | Afzender                                             |
| `REGISTRY` / `TAG`                  | `wolsels` / `latest`    | Naam en tag van de images                            |
| `BACKEND_CONTEXT`                   | `../wolsels_backend`    | Bouwcontext backend (pad of git-URL)                 |
| `FRONTEND_CONTEXT`                  | `../wolsels_frontend`   | Bron van de frontend voor `deploy-frontend.sh`       |

Na het wijzigen van `.env`: `docker compose up -d`. Pas je `WOLSELS_API_PORT` of `WOLSELS_WEB_ROOT` aan,
wijzig dan ook `proxy_pass` en `root` in de nginx-site.

## Beveiliging

- **Accounts:** wachtwoorden minimaal 10 tekens, veilig gehasht (ASP.NET Core Identity).
  Elke gebruiker ziet alleen zijn eigen gegevens.
- **Tweestapsverificatie:** in te stellen onder *Account* met een authenticator-app (TOTP),
  inclusief eenmalige herstelcodes.
- **Pogingen begrensd:** na 5 foute wachtwoorden of 2FA-codes is een account 15 minuten geblokkeerd;
  daarnaast een limiet per IP-adres per minuut en per uur, en voor herstelmails ook per e-mailadres.
- **Sessie:** HttpOnly-cookie met SameSite=Strict, `Secure` via HTTPS. Sleutels staan in het volume,
  zodat een herstart niemand uitlogt.
- **Headers:** Content-Security-Policy, X-Frame-Options, nosniff en Referrer-Policy via `nginx/wolsels.conf`.
- **Container:** de backend draait als niet-root gebruiker en is alleen via 127.0.0.1 bereikbaar.

## Beheer

```sh
docker compose logs -f backend      # logs
./scripts/update.sh                 # alles bijwerken: git pull, backend herbouwen, frontend uitrollen
./scripts/backup.sh                 # backup van de database naar ./backups
```

`backup.sh` stopt de backend een paar seconden zodat de database volledig is weggeschreven, en bewaart
de nieuwste 10 backups (`BACKUP_KEEP=20 ./scripts/backup.sh` voor meer). `update.sh` maakt vóór elke
update automatisch een backup. Kopieer `backups/` geregeld naar een andere plek.

`update.sh` haalt alle drie de repo's bij en stopt als er niets nieuws is (`--force` om toch te
herbouwen, bv. voor beveiligingsupdates van de base-images). Start de nieuwe backend niet goed, dan blijft
de oude frontend staan en toont het script de logs.

Terugzetten van een backup:

```sh
docker compose stop backend
docker compose run --rm --no-deps --user root -v "$PWD/backups:/backups" --entrypoint sh backend \
  -c 'cp /backups/<bestand>.db /data/wolsels.db && rm -f /data/wolsels.db-wal /data/wolsels.db-shm && chown $APP_UID /data/wolsels.db'
docker compose start backend
```

Een backup bevat de database (met alle accounts), niet de sleutels van de sessiecookies; na het
terugzetten moet iedereen hooguit opnieuw inloggen.
