#!/usr/bin/env sh
# Werkt Wolsels bij: haalt de nieuwste images (of code) op, maakt een backup en herstart de containers.
# De gegevens staan in het volume wolsels_wolsels-data en blijven bewaard.
#
# Standaard worden de images van ghcr.io gehaald. Staat docker-compose.build.yml in COMPOSE_FILE
# (zie .env.example), dan doet het git pull in de broncode-repo's en bouwt het de images zelf.
#
#   ./scripts/update.sh              bijwerken als er iets nieuws is
#   ./scripts/update.sh --force      ook herstarten (of herbouwen) als er niets nieuws is
#   ./scripts/update.sh --no-backup  zonder backup vooraf
set -eu
cd "$(dirname "$0")/.."

force=false
backup=true
self_updated=false
for arg in "$@"; do
  case "$arg" in
    --force) force=true ;;
    --no-backup) backup=false ;;
    --self-updated) self_updated=true ;;
    *) echo "Onbekende optie: $arg" >&2; exit 2 ;;
  esac
done

changed=false

# Haalt een repo bij en toont de nieuwe commits. Zet changed=true als er iets nieuws is.
pull() {
  dir="$1"
  before=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" pull --ff-only --quiet
  after=$(git -C "$dir" rev-parse HEAD)
  if [ "$before" != "$after" ]; then
    echo "  $(basename "$(cd "$dir" && pwd)"):"
    git -C "$dir" log --format='    %h %s' "$before..$after"
    changed=true
  fi
}

echo "Nieuwe versie ophalen ..."
if [ "$self_updated" = false ]; then
  before=$(git rev-parse HEAD)
  pull .
  # Dit script kan zelf veranderd zijn: opnieuw starten met de nieuwe versie.
  if [ "$before" != "$(git rev-parse HEAD)" ]; then
    exec "$0" "$@" --self-updated
  fi
else
  changed=true
fi

# Zelf bouwen als docker-compose.build.yml meedoet, anders images van de registry halen.
if docker compose config | grep -q '^ *build:'; then
  build=true
else
  build=false
fi

# Image-ID en versie (label van GitHub Actions) van een image, of "-" als hij er (nog) niet is.
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null </dev/null || echo -; }
# Versie van een draaiende container, of "niet gestart".
container_version() {
  if [ -z "$1" ]; then echo "niet gestart"; return; fi
  rev=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null </dev/null || true)
  case "$rev" in ""|"<no value>") rev="?" ;; esac
  echo "$rev"
}
image_rev() {
  rev=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null </dev/null || true)
  case "$rev" in ""|"<no value>") rev="?" ;; esac
  echo "$rev"
}

if [ "$build" = true ]; then
  pull ../wolsels_backend
  pull ../wolsels_frontend
else
  images=$(docker compose config --images)
  if echo "$images" | grep -q '^wolsels/'; then
    echo "REGISTRY=wolsels in .env hoort bij zelf bouwen. Zet REGISTRY=ghcr.io/hjeverts, of zet" >&2
    echo "docker-compose.build.yml in COMPOSE_FILE. Zie README (Overstappen naar images van ghcr.io)." >&2
    exit 1
  fi
  docker compose pull --quiet
  # Vergelijken met wat er draait (niet met wat er vóór de pull lokaal stond): zo wordt ook een
  # gewijzigde BACKEND_TAG/FRONTEND_TAG opgepakt waarvan de image al lokaal stond.
  # Image per service uit de genormaliseerde config. Niet "config --images <service>": dat geeft
  # ook de images van de services waarvan deze afhangt (depends_on).
  services=$(docker compose config | awk '
    /^services:/ { s = 1; next }
    s && /^[^ ]/ { s = 0 }
    s && /^  [^ ]/ { service = $1; sub(":$", "", service) }
    s && /^    image:/ { print service, $2 }
  ')
  # Geen pipe naar while: dan zou changed=true in een subshell verloren gaan.
  while read -r service image; do
    container=$(docker compose ps -q "$service" </dev/null)
    running=-
    [ -z "$container" ] || running=$(docker inspect -f '{{.Image}}' "$container" </dev/null)
    if [ "$running" != "$(image_id "$image")" ]; then
      echo "  $service: $(container_version "$container") -> $(image_rev "$image")"
      changed=true
    fi
  done <<EOF
$services
EOF
fi

if [ "$changed" = false ] && [ "$force" = false ]; then
  echo "Alles is al bijgewerkt. Gebruik --force om toch opnieuw te starten."
  exit 0
fi

# Backup vóór de update: de backend voert bij het starten automatisch databasemigraties uit.
if [ "$backup" = true ] && docker volume inspect wolsels_wolsels-data >/dev/null 2>&1; then
  echo "Backup maken ..."
  ./scripts/backup.sh
fi

if [ "$build" = true ]; then
  echo "Containers bouwen en starten ..."
  docker compose up -d --build --remove-orphans
else
  echo "Containers starten ..."
  if [ "$force" = true ]; then
    docker compose up -d --force-recreate --remove-orphans
  else
    docker compose up -d --remove-orphans
  fi
fi

# Wacht tot een service gezond is; geeft de status terug in $status.
wait_healthy() {
  printf "Wachten tot %s gezond is " "$1"
  container=$(docker compose ps -q "$1")
  for _ in $(seq 1 60); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container")
    [ "$status" = healthy ] && break
    if [ "$status" = unhealthy ] || [ "$status" = exited ]; then break; fi
    printf '.'
    sleep 2
  done
  echo " $status"
}

for service in backend frontend; do
  wait_healthy "$service"
  if [ "$status" != healthy ]; then
    echo "$service start niet goed. Laatste logregels:" >&2
    docker compose logs --tail 30 "$service" >&2
    echo "De gegevens zijn niet aangetast; een backup staat in backups/. Zie README (Beheer)." >&2
    exit 1
  fi
done

# Oude, niet meer gebruikte images opruimen.
docker image prune -f >/dev/null

echo "Klaar."
