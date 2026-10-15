#!/usr/bin/env sh
# Maakt een kopie van de SQLite-database naar ./backups/wolsels-<datum>.db
# De backend wordt kort gestopt zodat de database volledig (incl. WAL) is weggeschreven.
set -eu
cd "$(dirname "$0")/.."
mkdir -p backups
target="wolsels-$(date +%Y%m%d-%H%M%S).db"
owner="$(id -u):$(id -g)"

was_running=$(docker compose ps --status running --quiet backend)
[ -n "$was_running" ] && docker compose stop backend >/dev/null

docker compose run --rm --no-deps --user root -v "$PWD/backups:/backups" --entrypoint sh backend \
  -c "cp /data/wolsels.db /backups/$target && chown $owner /backups/$target" || status=$?

[ -n "$was_running" ] && docker compose start backend >/dev/null
[ "${status:-0}" -eq 0 ] || exit "$status"
echo "Backup gemaakt: backups/$target"

# Alleen de nieuwste backups bewaren (BACKUP_KEEP, standaard 10).
keep="${BACKUP_KEEP:-10}"
find backups -maxdepth 1 -name 'wolsels-*.db' | sort -r | tail -n +$((keep + 1)) | while read -r old; do rm -f "$old"; done
