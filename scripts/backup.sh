#!/usr/bin/env sh
# Maakt een consistente kopie van de SQLite-database naar ./backups/wolsels-<datum>.db
set -eu
cd "$(dirname "$0")/.."
mkdir -p backups
target="wolsels-$(date +%Y%m%d-%H%M%S).db"
docker compose run --rm --no-deps -v "$PWD/backups:/backups" --entrypoint sh backend \
  -c "cp /data/wolsels.db /backups/$target"
echo "Backup gemaakt: backups/$target"
