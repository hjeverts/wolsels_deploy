#!/usr/bin/env sh
# Werkt Wolsels bij: haalt de nieuwste code op, maakt een backup, herbouwt de backend en zet de
# frontend live.
#
#   ./scripts/update.sh              bijwerken als er iets nieuws is
#   ./scripts/update.sh --force      ook herbouwen als er niets nieuws is (bv. voor nieuwe base-images)
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

echo "Nieuwe code ophalen ..."
if [ "$self_updated" = false ]; then
  before=$(git rev-parse HEAD)
  pull .
  # Dit script kan zelf veranderd zijn: opnieuw starten met de nieuwe versie.
  if [ "$before" != "$(git rev-parse HEAD)" ]; then
    set -- "$@" --self-updated
    [ "$force" = true ] || set -- "$@" --force
    exec "$0" "$@"
  fi
fi
pull ../wolsels_backend
pull ../wolsels_frontend

if [ "$changed" = false ] && [ "$force" = false ]; then
  echo "Alles is al bijgewerkt. Gebruik --force om toch opnieuw te bouwen."
  exit 0
fi

# Backup vóór de update: de backend voert bij het starten automatisch databasemigraties uit.
if [ "$backup" = true ] && docker volume inspect wolsels_wolsels-data >/dev/null 2>&1; then
  echo "Backup maken ..."
  ./scripts/backup.sh
fi

echo "Backend bouwen en starten ..."
docker compose up -d --build --remove-orphans

printf "Wachten tot de backend gezond is "
container=$(docker compose ps -q backend)
for _ in $(seq 1 60); do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container")
  [ "$status" = healthy ] && break
  if [ "$status" = unhealthy ] || [ "$status" = exited ]; then break; fi
  printf '.'
  sleep 2
done
echo " $status"
if [ "$status" != healthy ]; then
  echo "De backend start niet goed. Laatste logregels:" >&2
  docker compose logs --tail 30 backend >&2
  echo "De frontend is NIET bijgewerkt. Terugzetten van de backup: zie README (Beheer)." >&2
  exit 1
fi

echo "Frontend uitrollen ..."
./scripts/deploy-frontend.sh

# Oude, niet meer gebruikte images opruimen.
docker image prune -f >/dev/null

echo "Klaar."
