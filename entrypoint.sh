#!/bin/bash
# ==============================================================================
#  entrypoint.sh — Vaultwarden en Railway
#
#  Hace dos cosas antes de ceder el control a Vaultwarden:
#    1. RESTAURACIÓN (opcional): si existe la variable RESTORE_FROM y /data
#       está vacío, baja el backup de R2, lo descifra y lo coloca en /data.
#    2. BACKUP: lanza en segundo plano el bucle que sube copias cifradas a R2.
#
#  En un deploy normal el bloque de restauración no se ejecuta: RESTORE_FROM
#  no existe. Y aunque existiera, la comprobación de /data/db.sqlite3 impide
#  que un redeploy machaque datos buenos.
# ==============================================================================
set -e

# ---------------------------------------------------------- RESTAURACIÓN -----
# Uso: pon RESTORE_FROM=latest (o un timestamp concreto como 20260830-1615)
#      y AGE_IDENTITY con tu clave privada age. QUITA AMBAS al terminar.

if [ -n "${RESTORE_FROM:-}" ] && [ ! -f /data/db.sqlite3 ]; then
  echo "[restore] === MODO RESTAURACIÓN ==="

  : "${AGE_IDENTITY:?falta AGE_IDENTITY (la clave privada AGE-SECRET-KEY-1...)}"
  : "${S3_KEY:?falta S3_KEY}"
  : "${S3_SECRET:?falta S3_SECRET}"
  : "${S3_BUCKET:?falta S3_BUCKET}"
  : "${S3_ENDPOINT:?falta S3_ENDPOINT}"

  export RCLONE_CONFIG=/dev/null
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$S3_KEY"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$S3_SECRET"
  export RCLONE_CONFIG_R2_ENDPOINT="$S3_ENDPOINT"
  export RCLONE_CONFIG_R2_REGION=auto
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

  PREFIX="${S3_PREFIX:-vw-empresa}"

  # "latest" resuelve automáticamente al backup más reciente
  if [ "$RESTORE_FROM" = "latest" ]; then
    RESTORE_FROM=$(rclone lsf "r2:${S3_BUCKET}/${PREFIX}/" \
      | grep '\.tar\.gz\.age$' | sort | tail -1)
    RESTORE_FROM="${RESTORE_FROM%.tar.gz.age}"
    [ -n "$RESTORE_FROM" ] || { echo "[restore] No hay backups en r2:${S3_BUCKET}/${PREFIX}/"; exit 1; }
    echo "[restore] Último backup disponible: $RESTORE_FROM"
  fi

  T=$(mktemp -d)

  echo "[restore] Descargando ${RESTORE_FROM}.tar.gz.age ..."
  rclone copyto "r2:${S3_BUCKET}/${PREFIX}/${RESTORE_FROM}.tar.gz.age" "$T/bk.age" \
    || { echo "[restore] FALLO al descargar"; rm -rf "$T"; exit 1; }

  echo "[restore] Descifrando ..."
  printf '%s\n' "$AGE_IDENTITY" > "$T/key.txt"
  chmod 600 "$T/key.txt"
  age -d -i "$T/key.txt" -o "$T/bk.tar.gz" "$T/bk.age" \
    || { echo "[restore] FALLO al descifrar: ¿es la clave age correcta?"; rm -rf "$T"; exit 1; }

  echo "[restore] Extrayendo en /data ..."
  mkdir -p /data
  tar xzf "$T/bk.tar.gz" -C /data --strip-components=1
  rm -rf "$T"

  if [ -f /data/db.sqlite3 ] && [ "$(sqlite3 /data/db.sqlite3 'PRAGMA integrity_check;')" = "ok" ]; then
    N=$(sqlite3 /data/db.sqlite3 'SELECT COUNT(*) FROM ciphers;' 2>/dev/null || echo '?')
    echo "[restore] OK — base de datos íntegra, $N items"
  else
    echo "[restore] AVISO: la base de datos restaurada no pasa integrity_check"
  fi

  echo "[restore] ============================================================"
  echo "[restore]  IMPORTANTE: borra ahora las variables RESTORE_FROM y"
  echo "[restore]  AGE_IDENTITY en Railway y vuelve a desplegar."
  echo "[restore]  Con AGE_IDENTITY presente, la clave privada vive en el"
  echo "[restore]  mismo sitio que los backups y el cifrado deja de proteger."
  echo "[restore] ============================================================"

elif [ -n "${RESTORE_FROM:-}" ]; then
  echo "[restore] RESTORE_FROM está definida pero /data/db.sqlite3 ya existe."
  echo "[restore] No se restaura nada (protección contra sobrescritura)."
  echo "[restore] Si de verdad quieres restaurar, vacía el volumen primero."
fi

# --------------------------------------------------- Plantillas de Emial-----
if [ -d /opt/templates ]; then
  mkdir -p /data/templates
  cp -r /opt/templates/* /data/templates/
  echo "[templates] Plantillas personalizadas instaladas"
fi

# --------------------------------------------------------------- BACKUP -----

(
  sleep 90   # deja que Vaultwarden arranque y cree la base de datos
  while true; do
    /usr/local/bin/backup.sh || echo "[backup] FALLO en la ejecución"
    sleep "${BACKUP_INTERVAL:-21600}"
  done
) &

# ---------------------------------------------------------- VAULTWARDEN -----
# En primer plano, para que reciba las señales de Railway y cierre limpio.

exec /start.sh
