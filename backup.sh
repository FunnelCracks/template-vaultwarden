#!/bin/bash
# Backup de /data cifrado con age y subido a Cloudflare R2.
# Todas las opciones vienen de variables de entorno de Railway.
set -euo pipefail

: "${AGE_RECIPIENT:?falta AGE_RECIPIENT}"
: "${S3_KEY:?falta S3_KEY}"
: "${S3_SECRET:?falta S3_SECRET}"
: "${S3_BUCKET:?falta S3_BUCKET}"
: "${S3_ENDPOINT:?falta S3_ENDPOINT}"
PREFIX="${S3_PREFIX:-vw}"

TS=$(date -u +%Y%m%d-%H%M%S)
WORK=$(mktemp -d)
STAGE="$WORK/vw-$TS"
mkdir -p "$STAGE"
trap 'rm -rf "$WORK"' EXIT

hc() { [ -n "${HC_URL:-}" ] && curl -fsS -m 10 "${HC_URL}$1" >/dev/null 2>&1 || true; }
hc "/start"

# 1. Copia consistente: nunca copiar el .sqlite3 en caliente
sqlite3 /data/db.sqlite3 ".backup '$STAGE/db.sqlite3'"

# 2. Verificar la copia ANTES de cifrarla y subirla
if [ "$(sqlite3 "$STAGE/db.sqlite3" 'PRAGMA integrity_check;')" != "ok" ]; then
  echo "[backup] integrity_check FALLIDO"
  hc "/fail"
  exit 1
fi

# 3. Sin las rsa_key no se restauran las sesiones
for f in rsa_key.pem rsa_key.pub.pem config.json; do
  [ -f "/data/$f" ] && cp "/data/$f" "$STAGE/" || true
done
[ -d /data/attachments ] && cp -r /data/attachments "$STAGE/" || true
[ -d /data/sends ]       && cp -r /data/sends       "$STAGE/" || true

# 4. Empaquetar y cifrar con clave PÚBLICA:
#    el servidor no puede descifrar sus propios backups
tar czf "$WORK/bk.tar.gz" -C "$WORK" "vw-$TS"
age -r "$AGE_RECIPIENT" -o "$WORK/bk.tar.gz.age" "$WORK/bk.tar.gz"

# 5. Subir a R2
#    no_check_bucket es obligatorio con tokens acotados a un solo bucket:
#    sin él rclone intenta CreateBucket y R2 responde 403.
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$S3_KEY"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$S3_SECRET"
export RCLONE_CONFIG_R2_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG=/dev/null

rclone copyto "$WORK/bk.tar.gz.age" "r2:${S3_BUCKET}/${PREFIX}/${TS}.tar.gz.age"

echo "[backup] $TS OK ($(du -h "$WORK/bk.tar.gz.age" | cut -f1))"
hc ""
