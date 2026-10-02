FROM vaultwarden/server:1.37.2

ARG RCLONE_VERSION=v1.71.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      sqlite3 age curl ca-certificates unzip dumb-init \
 && curl -fsSL "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip" -o /tmp/rclone.zip \
 && unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin/ \
 && chmod +x /usr/local/bin/rclone \
 && rm -rf /tmp/rclone.zip /var/lib/apt/lists/*

COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

# dumb-init es el entrypoint de la imagen oficial y gestiona las señales.
# Sin él, Vaultwarden no cierra limpio en los redeploys y arriesgas
# corrupción de la base de datos SQLite.
COPY templates /opt/templates
ENTRYPOINT ["dumb-init", "--", "/usr/local/bin/entrypoint.sh"]
