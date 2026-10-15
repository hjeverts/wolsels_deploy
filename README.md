# Wolsels deploy

Docker Compose-configuratie voor Wolsels: bijhouden van wolvoorraad, mengsels, spinresultaten en de
productie van ruwe wol door eigen dieren.

| Repo                                        | Inhoud                                   |
|---------------------------------------------|------------------------------------------|
| [wolsels-backend](../wolsels-backend)       | ASP.NET Core API + SQLite                |
| [wolsels-frontend](../wolsels-frontend)     | Angular-app, geserveerd door nginx       |
| wolsels-deploy (deze)                       | Docker Compose, configuratie, backups    |

## Starten

Zet de drie repo's naast elkaar:

```
wolsels-backend/
wolsels-frontend/
wolsels-deploy/
```

```sh
cd wolsels-deploy
cp .env.example .env        # optioneel, om poort of instellingen aan te passen
docker compose up -d --build
```

Wolsels draait dan op <http://localhost:8080>.

## Architectuur

```
browser ──► frontend (nginx :80) ──/api/──► backend (:8080) ──► SQLite (volume wolsels-data)
```

Alleen de frontend is van buitenaf bereikbaar; nginx stuurt `/api/*` door naar de backend.
De database wordt bij het opstarten automatisch aangemaakt en gemigreerd.

## Configuratie (`.env`)

| Variabele              | Standaard              | Omschrijving                                    |
|------------------------|------------------------|-------------------------------------------------|
| `WOLSELS_PORT`         | `8080`                 | Poort op de host                                |
| `MAX_BLEND_COMPONENTS` | `6`                    | Maximaal aantal soorten wol per mengsel         |
| `REGISTRY` / `TAG`     | `wolsels` / `latest`   | Naam en tag van de images                       |
| `BACKEND_CONTEXT`      | `../wolsels-backend`   | Bouwcontext backend (pad of git-URL)            |
| `FRONTEND_CONTEXT`     | `../wolsels-frontend`  | Bouwcontext frontend (pad of git-URL)           |

De bouwcontexten mogen ook git-URL's zijn, bv.
`BACKEND_CONTEXT=https://github.com/<account>/wolsels-backend.git#main`.

Images uit een registry gebruiken in plaats van lokaal bouwen:

```sh
docker compose pull && docker compose up -d --no-build
```

## Beheer

```sh
docker compose logs -f backend     # logs
docker compose pull / up -d --build # bijwerken
./scripts/backup.sh                # backup van de database naar ./backups
```

`backup.sh` stopt de backend een paar seconden zodat de database volledig is weggeschreven.

Terugzetten van een backup:

```sh
docker compose stop backend
docker compose run --rm --no-deps --user root -v "$PWD/backups:/backups" --entrypoint sh backend \
  -c 'cp /backups/<bestand>.db /data/wolsels.db && rm -f /data/wolsels.db-wal /data/wolsels.db-shm && chown $APP_UID /data/wolsels.db'
docker compose start backend
```
