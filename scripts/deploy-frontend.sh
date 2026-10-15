#!/usr/bin/env sh
# Bouwt de frontend (in Docker, zonder Node op de server) en zet hem klaar voor de nginx op de server.
#
#   <WEBROOT>/releases/<tijdstip>/   één map per versie
#   <WEBROOT>/current -> releases/…  waar nginx naar kijkt; wordt in één keer omgezet
#
# Terugdraaien: ln -sfn releases/<vorige> <WEBROOT>/current
set -eu
cd "$(dirname "$0")/.."

# Alleen de benodigde waarden uit .env lezen (het bestand niet uitvoeren).
env_value() { if [ -f .env ]; then sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '"'"'"; fi; }
WEB_ROOT="${WOLSELS_WEB_ROOT:-$(env_value WOLSELS_WEB_ROOT)}"
WEB_ROOT="${WEB_ROOT:-/var/www/wolsels}"
CONTEXT="${FRONTEND_CONTEXT:-$(env_value FRONTEND_CONTEXT)}"
CONTEXT="${CONTEXT:-../wolsels_frontend}"
KEEP=3

if [ ! -w "$WEB_ROOT" ]; then
  echo "Geen schrijfrechten op $WEB_ROOT. Eenmalig: sudo mkdir -p $WEB_ROOT && sudo chown $(id -un) $WEB_ROOT" >&2
  exit 1
fi

release="$WEB_ROOT/releases/$(date +%Y%m%d-%H%M%S)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Frontend bouwen uit $CONTEXT ..."
docker build --quiet --output "type=local,dest=$tmp" "$CONTEXT" >/dev/null
[ -f "$tmp/index.html" ] || { echo "Build bevat geen index.html" >&2; exit 1; }

mkdir -p "$release"
cp -R "$tmp/." "$release/"
chmod -R a+rX "$release"

# Symlink atomair omzetten.
ln -sfn "$release" "$WEB_ROOT/current.new"
mv -T "$WEB_ROOT/current.new" "$WEB_ROOT/current"
echo "Actief: $release"

# Oude versies opruimen.
ls -1d "$WEB_ROOT"/releases/*/ | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do rm -rf "$old"; done
