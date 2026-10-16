#!/usr/bin/env sh
# Updates Wolsels: fetches the newest images (or code), makes a backup and restarts the containers.
# The data lives in the volume wolsels_wolsels-data and is kept.
#
# By default the images are pulled from ghcr.io. If docker-compose.build.yml is in COMPOSE_FILE
# (see .env.example), it runs git pull in the source repos and builds the images itself.
#
#   ./scripts/update.sh              update if there is something new
#   ./scripts/update.sh --force      also restart (or rebuild) if there is nothing new
#   ./scripts/update.sh --no-backup  without a backup first
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
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

changed=false

# Updates a repo and shows the new commits. Sets changed=true if there is something new.
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

echo "Fetching new version ..."
if [ "$self_updated" = false ]; then
  before=$(git rev-parse HEAD)
  pull .
  # This script itself may have changed: restart with the new version.
  if [ "$before" != "$(git rev-parse HEAD)" ]; then
    exec "$0" "$@" --self-updated
  fi
else
  changed=true
fi

# Build ourselves if docker-compose.build.yml is included, otherwise pull images from the registry.
if docker compose config | grep -q '^ *build:'; then
  build=true
else
  build=false
fi

# Image ID and version (label from GitHub Actions) of an image, or "-" if it isn't there (yet).
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null </dev/null || echo -; }
# Version of a running container, or "not started".
container_version() {
  if [ -z "$1" ]; then echo "not started"; return; fi
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
    echo "REGISTRY=wolsels in .env belongs to building yourself. Set REGISTRY=ghcr.io/hjeverts, or put" >&2
    echo "docker-compose.build.yml in COMPOSE_FILE. See README (Switching to images from ghcr.io)." >&2
    exit 1
  fi
  docker compose pull --quiet
  # Compare with what is running (not with what was local before the pull): that way a changed
  # BACKEND_TAG/FRONTEND_TAG whose image was already local is picked up too.
  # Image per service from the normalised config. Not "config --images <service>": that also returns
  # the images of the services this one depends on (depends_on).
  services=$(docker compose config | awk '
    /^services:/ { s = 1; next }
    s && /^[^ ]/ { s = 0 }
    s && /^  [^ ]/ { service = $1; sub(":$", "", service) }
    s && /^    image:/ { print service, $2 }
  ')
  # No pipe into while: changed=true would then be lost in a subshell.
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
  echo "Everything is up to date. Use --force to restart anyway."
  exit 0
fi

# Backup before the update: the backend runs database migrations automatically at startup.
if [ "$backup" = true ] && docker volume inspect wolsels_wolsels-data >/dev/null 2>&1; then
  echo "Creating backup ..."
  ./scripts/backup.sh
fi

if [ "$build" = true ]; then
  echo "Building and starting containers ..."
  docker compose up -d --build --remove-orphans
else
  echo "Starting containers ..."
  if [ "$force" = true ]; then
    docker compose up -d --force-recreate --remove-orphans
  else
    docker compose up -d --remove-orphans
  fi
fi

# Waits until a service is healthy; returns the status in $status.
wait_healthy() {
  printf "Waiting until %s is healthy " "$1"
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
    echo "$service does not start properly. Last log lines:" >&2
    docker compose logs --tail 30 "$service" >&2
    echo "The data is unaffected; a backup is in backups/. See README (Maintenance)." >&2
    exit 1
  fi
done

# Clean up old, unused images.
docker image prune -f >/dev/null

echo "Done."
