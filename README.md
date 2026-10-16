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

Nodig op de server: Docker (met Compose) en nginx. Node of .NET zijn niet nodig: de images worden
door GitHub Actions gebouwd en van ghcr.io gehaald (zie [Images](#images)).

```sh
git clone https://github.com/hjeverts/wolsels_deploy.git

cd wolsels_deploy
cp .env.example .env && chmod 600 .env
nano .env                                    # o.a. WOLSELS_PORT, WOLSELS_PUBLIC_URL, mailserver
docker compose up -d                         # Wolsels op 127.0.0.1:<WOLSELS_PORT>

sudo cp nginx/wolsels.conf /etc/nginx/sites-available/wolsels   # poort in proxy_pass controleren
sudo ln -s /etc/nginx/sites-available/wolsels /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d wolsels.example.nl    # HTTPS
```

Zet na certbot de `Strict-Transport-Security`-regel in de site aan. Gebruik altijd HTTPS: de
sessiecookie wordt dan als `Secure` verstuurd.

Maak daarna direct je eigen account aan: het **eerste account** wordt beheerder en neemt eventuele
gegevens van vóór de invoering van accounts over. Zet daarna in `.env` `ALLOW_REGISTRATION=false`
als anderen zich niet zelf mogen aanmelden (en `docker compose up -d`); via een uitnodigingslink
voor een huishouden kan iemand dan nog steeds een account aanmaken.

## Huishoudens en beheer

- **Huishouden:** gegevens horen bij een huishouden. Nodig je partner uit via *Huishouden → Uitnodigingslink
  maken* en stuur de link zelf door; jullie zien en bewerken dan dezelfde gegevens, ieder met een eigen
  login en 2FA. Iemand kan lid zijn van meerdere huishoudens en wisselt bovenin.
- **Beheerder:** het eerste account (bij bestaande installaties: de maker van het eerste huishouden).
  Onder *Gebruikersbeheer*: accounts blokkeren, 2FA resetten, een herstellink voor een nieuw wachtwoord
  maken, beheerders aanwijzen en accounts verwijderen. Beheerders zien geen gegevens van huishoudens.
- **Buitengesloten?** Zet `ADMIN_EMAIL=jouw@adres.nl` in `.env` en `docker compose up -d`: dat account
  wordt bij het opstarten beheerder.

Welke poort is vrij? `ss -tln | grep -q ':8083 ' && echo bezet || echo vrij`

## Foto's bij de voorraad (backend en frontend vanaf v1.1.0)

Voor het uploaden van foto's moet de nginx op de server grotere verzoeken toestaan (4 MB in plaats van
1 MB). Kopieer `nginx/wolsels.conf` hiervoor niet opnieuw: certbot heeft de site op de server aangepast
voor HTTPS. Pas alleen die ene regel aan:

```sh
sudo sed -i 's/client_max_body_size 1m;/client_max_body_size 4m;/' /etc/nginx/sites-available/wolsels
sudo nginx -t && sudo systemctl reload nginx
```

Zonder deze aanpassing krijg je bij grotere foto's de melding *Er ging iets mis (413)*. Foto's staan in de
database en zitten dus gewoon in de backups.

## Overstappen naar images van ghcr.io

Bouwde je de images tot nu toe op de server? Pas dan in `.env` de images-instellingen aan:

```sh
REGISTRY=ghcr.io/hjeverts       # was: wolsels
TAG=latest
# BACKEND_CONTEXT en FRONTEND_CONTEXT mogen weg
```

Doe dit vóór de eerste `./scripts/update.sh` met de nieuwe versie; met `REGISTRY=wolsels` zou het
script proberen images van Docker Hub te halen. Draai daarna:

```sh
git pull --ff-only
./scripts/update.sh --force
```

De mappen `../wolsels_backend` en `../wolsels_frontend` zijn daarna niet meer nodig. Je gegevens in
het volume blijven gewoon staan.

## Overstappen van de versie zonder frontend-container

Heb je Wolsels eerder geïnstalleerd met `deploy-frontend.sh` en `/var/www/wolsels`? Je gegevens staan in
het Docker-volume `wolsels_wolsels-data` en blijven bij de overstap gewoon staan.

```sh
cd wolsels_deploy
./scripts/backup.sh                          # voor de zekerheid
git pull --ff-only
docker compose up -d --remove-orphans
```

Werk eerst `.env` bij zoals beschreven onder [Overstappen naar images van ghcr.io](#overstappen-naar-images-van-ghcrio).

Je bestaande `WOLSELS_API_PORT` in `.env` wordt automatisch als poort gebruikt (hernoemen naar
`WOLSELS_PORT` mag). Vervang daarna de nginx-site door de nieuwe, eenvoudigere versie; certbot past
die opnieuw aan voor HTTPS:

```sh
sudo cp nginx/wolsels.conf /etc/nginx/sites-available/wolsels   # poort in proxy_pass controleren
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d wolsels.example.nl
```

`/var/www/wolsels` is daarna niet meer nodig (`sudo rm -r /var/www/wolsels`).

## Architectuur

```
browser ──► nginx op de server (TLS, nginx/wolsels.conf)
              └── alles ──► frontend-container (nginx, 127.0.0.1:<WOLSELS_PORT>)
                              ├── /       Angular-app
                              └── /api/ ──► backend-container ──► SQLite + sleutels (volume wolsels-data)
```

- De nginx op de server doet alleen TLS en één `proxy_pass`, en geeft het echte IP van de bezoeker door
  (de pogingslimieten werken per IP).
- De frontend-container serveert de app, stuurt `/api/` door naar de backend en zet de
  beveiligingsheaders. Hij neemt het client-IP alleen over van proxies op interne netwerken.
- De backend is alleen via de frontend-container bereikbaar. De database wordt bij het opstarten
  automatisch aangemaakt en gemigreerd.
- Beide containers draaien als niet-root gebruiker en hebben een healthcheck.

## Configuratie (`.env`)

| Variabele                           | Standaard               | Omschrijving                                         |
|-------------------------------------|-------------------------|------------------------------------------------------|
| `WOLSELS_PUBLIC_URL`                | –                       | Openbare URL (voor links in e-mails)                 |
| `WOLSELS_PORT`                      | `8080`                  | Poort op 127.0.0.1 (= `proxy_pass` in de nginx-site) |
| `MAX_BLEND_COMPONENTS`              | `6`                     | Maximaal aantal soorten wol per mengsel              |
| `ALLOW_REGISTRATION`                | `true`                  | Zelf registreren toestaan (eerste account en uitnodigingen mogen altijd) |
| `ADMIN_EMAIL`                       | –                       | Dit account wordt altijd beheerder (herstel)         |
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
| `REGISTRY` / `TAG`                  | `ghcr.io/hjeverts` / `latest` | Registry en tag van de images                  |
| `BACKEND_TAG` / `FRONTEND_TAG`      | `TAG`                   | Vaste versie per image, bv. `1.2.0`                  |
| `COMPOSE_FILE`                      | –                       | Met `docker-compose.build.yml` erbij: zelf bouwen    |
| `BACKEND_CONTEXT`                   | `../wolsels_backend`    | Bouwcontext backend bij zelf bouwen (pad of git-URL) |
| `FRONTEND_CONTEXT`                  | `../wolsels_frontend`   | Bouwcontext frontend bij zelf bouwen                 |

Na het wijzigen van `.env`: `docker compose up -d`. Pas je `WOLSELS_PORT` aan, wijzig dan ook
`proxy_pass` in de nginx-site.

## Images

[wolsels_backend](https://github.com/hjeverts/wolsels_backend) en
[wolsels_frontend](https://github.com/hjeverts/wolsels_frontend) hebben elk hun eigen versienummers.
Een image wordt alleen gebouwd als je in die repo een versietag maakt; mergen naar `main` draait
alleen de tests. Zo kun je meerdere wijzigingen verzamelen en ze samen uitbrengen.

```sh
cd wolsels_backend                            # alleen de repo('s) die gewijzigd zijn
git switch main && git pull
git tag v1.2.0 && git push origin v1.2.0      # of via GitHub: Releases → Draft a new release
```

Na een paar minuten staat de image op ghcr.io; draai daarna op de server `./scripts/update.sh`.
Gebruik [semver](https://semver.org/lang/nl/): `v1.2.1` voor een bugfix, `v1.3.0` voor een nieuwe
functie. Heeft de frontend een nieuwe backendfunctie nodig, breng dan eerst de backend uit.

| Image                                 | Tags                                                     |
|---------------------------------------|----------------------------------------------------------|
| `ghcr.io/hjeverts/wolsels-backend`    | `1.2.0`, `1.2` en `latest` (de nieuwste versie)          |
| `ghcr.io/hjeverts/wolsels-frontend`   | idem, met eigen versienummers                            |

Elke maandag wordt de nieuwste versie zonder cache opnieuw gebouwd, zodat beveiligingsupdates van de
base-images meekomen; `./scripts/update.sh` haalt die vanzelf op.

**Een vaste of eerdere versie:** zet in `.env` `BACKEND_TAG=1.1.0` en/of `FRONTEND_TAG=1.0.0` (de
versies staan bij de packages op GitHub) en draai `./scripts/update.sh`. Haal de regel weg om weer
`latest` te volgen. Let op: een oudere backend kent nieuwere databasemigraties niet; zet zo nodig ook
de backup van vóór de update terug.

**Zelf bouwen** in plaats van ghcr.io gebruiken (bv. voor eigen aanpassingen): clone
`wolsels_backend` en `wolsels_frontend` naast deze repo en zet in `.env`:

```sh
COMPOSE_FILE=docker-compose.yml:docker-compose.build.yml
REGISTRY=wolsels
```

`./scripts/update.sh` doet dan `git pull` in de broncode-repo's en bouwt de images op de server.

## Beveiliging

- **Accounts:** wachtwoorden minimaal 10 tekens, veilig gehasht (ASP.NET Core Identity).
  Elke gebruiker ziet alleen zijn eigen gegevens.
- **Tweestapsverificatie:** in te stellen onder *Account* met een authenticator-app (TOTP),
  inclusief eenmalige herstelcodes.
- **Pogingen begrensd:** na 5 foute wachtwoorden of 2FA-codes is een account 15 minuten geblokkeerd;
  daarnaast een limiet per IP-adres per minuut en per uur, en voor herstelmails ook per e-mailadres.
- **Sessie:** HttpOnly-cookie met SameSite=Strict, `Secure` via HTTPS. Sleutels staan in het volume,
  zodat een herstart niemand uitlogt.
- **Headers:** Content-Security-Policy, X-Frame-Options, nosniff en Referrer-Policy via de frontend-container.
- **Containers:** draaien als niet-root gebruiker; alleen de frontend is bereikbaar, en dan alleen via 127.0.0.1.

## Beheer

```sh
docker compose logs -f backend      # logs
./scripts/update.sh                 # bijwerken: nieuwe images ophalen, backup, herstarten
./scripts/backup.sh                 # backup van de database naar ./backups
```

`backup.sh` stopt de backend een paar seconden zodat de database volledig is weggeschreven, en bewaart
de nieuwste 10 backups (`BACKUP_KEEP=20 ./scripts/backup.sh` voor meer). `update.sh` maakt vóór elke
update automatisch een backup. Kopieer `backups/` geregeld naar een andere plek.

`update.sh` haalt deze repo bij en daarna de nieuwste images (bij zelf bouwen: de broncode-repo's), en
toont welke versies er nieuw zijn. Is er niets nieuws, dan stopt het (`--force` om de containers toch
opnieuw te starten, of bij zelf bouwen opnieuw te bouwen). Daarna wacht het tot beide containers gezond
zijn en toont anders de logs. De gegevens in het volume blijven bij updates altijd staan; gebruik nooit
`docker compose down -v`, want `-v` verwijdert het volume met alle gegevens.

Terugzetten van een backup:

```sh
docker compose stop backend
docker compose run --rm --no-deps --user root -v "$PWD/backups:/backups" --entrypoint sh backend \
  -c 'cp /backups/<bestand>.db /data/wolsels.db && rm -f /data/wolsels.db-wal /data/wolsels.db-shm && chown $APP_UID /data/wolsels.db'
docker compose start backend
```

Een backup bevat de database (met alle accounts), niet de sleutels van de sessiecookies; na het
terugzetten moet iedereen hooguit opnieuw inloggen.

## Licentie

[MIT](LICENSE) © 2026 Hans Everts
