# Vaultwarden en Railway con backups cifrados

Plantilla para desplegar [Vaultwarden](https://github.com/dani-garcia/vaultwarden)
en Railway con un sistema de backups propio: copias cifradas cada 6 horas a
Cloudflare R2, alerta si dejan de subir, y restauración en un clic desde una
variable de entorno.

**Monta esto en unos 45 minutos.** No requiere plan Pro de Railway.

---

## Qué incluye

```
├── Dockerfile        # imagen oficial + sqlite3, age, rclone
├── entrypoint.sh     # restauración opcional + bucle de backup + arranque
├── backup.sh         # copia, verifica, cifra y sube a R2
└── .env.example      # todas las variables, documentadas
```

**Diseño del backup:**

- `sqlite3 .backup` para una copia consistente — nunca se copia la base en caliente
- `PRAGMA integrity_check` antes de subir — no se guardan backups corruptos
- Cifrado con `age` usando clave **pública**: el servidor no puede descifrar sus
  propios backups, así que comprometer Railway y R2 a la vez no basta para leerlos
- Incluye `rsa_key.pem`, sin la cual se pierden todas las sesiones al restaurar

---

## Montaje

### 1. Cloudflare R2

1. Crea un bucket
2. Settings → **Object lifecycle rules** → eliminar objetos a los 30 días
3. **Manage API Tokens** → `Create API Token`:
   - Permisos: **Object Read & Write**
   - Scope: **solo ese bucket**
4. Apunta el *Access Key ID* y el *Secret Access Key*

> ⚠️ Cloudflare muestra tres valores. El **Token Value no sirve** para el
> protocolo S3 — si lo pegas por error, obtendrás un `403 AccessDenied`
> difícil de diagnosticar.

### 2. Claves de cifrado

```bash
age-keygen -o backup-key.txt
```

La clave **pública** (`age1...`) va a Railway. La **privada**
(`AGE-SECRET-KEY-1...`) la sacas del ordenador: papel y copia offline.

> ⚠️ **No guardes la clave privada dentro de Vaultwarden.** Si la bóveda muere y
> la única copia está dentro, no podrás abrir el backup que la salvaría.

### 3. Healthchecks

Crea un check en [healthchecks.io](https://healthchecks.io) con período **6 h** y
margen **2 h**, y activa el aviso por email. Copia la ping URL.

Sin esto no te enteras si los backups dejan de subir, que es el modo de fallo más
habitual de cualquier sistema de backup.

### 4. Railway

1. `+ New` → `GitHub Repo` → este repo
2. **Antes del primer deploy**, crea el **Volume** montado en `/data`
3. Settings → Networking → `Generate Domain`, target port **8080**
4. Variables: copia las de `.env.example` y rellénalas
5. Deploy

A los ~90 segundos del arranque, en los logs:

```
[backup] 20260830-1615 OK (28K)
```

Comprueba las tres cosas: el objeto en R2, el check en verde, y el vault accesible.

### 5. Cierra la puerta

1. Entra por web y crea tu cuenta. Master password larga, **guardada en papel** —
   no hay recuperación
2. Cambia `SIGNUPS_ALLOWED` a `false` y redespliega
3. Activa 2FA en tu cuenta

---

## Correo

Railway **bloquea el SMTP saliente** en los planes Free, Trial y Hobby. Sin
correo, Vaultwarden funciona, pero tienes que confirmar cada usuario a mano desde
el panel admin.

Dos salidas:

- **Plan Pro** → SMTP directo, sin más
- **Servicio relay** → un segundo servicio que recibe SMTP por la red privada de
  Railway y reenvía por la API HTTPS de Resend (u otro transaccional)

Si montas el relay: **no le generes dominio público**. Un relay SMTP expuesto a
internet se convierte en máquina de spam en horas.

---

## Recuperación

### Restaurar en un servicio nuevo de Railway

1. Nuevo servicio desde este repo
2. **Antes del primer deploy**, crea el volumen en `/data`
3. Copia todas las variables del servicio original
4. Añade estas dos:
   ```
   RESTORE_FROM=latest        # o un timestamp: 20260830-1615
   AGE_IDENTITY=AGE-SECRET-KEY-1...
   ```
5. Deploy. En los logs:
   ```
   [restore] OK — base de datos íntegra, 142 items
   ```
6. Genera el dominio y ajusta `DOMAIN`
7. **Borra `RESTORE_FROM` y `AGE_IDENTITY`** y redespliega

> ⚠️ El paso 7 no es opcional. Mientras `AGE_IDENTITY` esté en Railway, tu clave
> privada vive junto a los backups y el cifrado deja de servir de nada.

**Protección:** si `/data/db.sqlite3` ya existe, no se restaura nada aunque
`RESTORE_FROM` esté puesta. Un redeploy accidental no puede machacar datos buenos.

### Restauración manual

```bash
rclone copyto r2:BUCKET/PREFIJO/TIMESTAMP.tar.gz.age ./bk.age
age -d -i backup-key.txt -o bk.tar.gz bk.age
mkdir data && tar xzf bk.tar.gz -C data --strip-components=1
sqlite3 data/db.sqlite3 'PRAGMA integrity_check;'   # debe decir: ok
```

Listar los backups disponibles: `rclone lsf r2:BUCKET/PREFIJO/`

> ⚠️ Con un token de R2 acotado a un bucket, rclone necesita
> `no_check_bucket = true` en su configuración. Sin esa opción intenta un
> `CreateBucket` previo y R2 responde 403.

### Prueba de restauración

**Un backup sin restauración probada no es un backup.** Haz la prueba al montarlo
y repítela cada vez que actualices de versión. Anota la fecha.

> ⚠️ Al verificar en local, Vaultwarden **debe servirse por HTTPS**: el cliente
> web de Bitwarden rechaza URLs `http://` incluso en localhost, con el error
> *"Insecure URL not allowed"*. Hace falta un proxy con TLS (Caddy con
> `local_certs` sirve).

---

## Mantenimiento

### Actualizar de versión

La imagen está **pinneada a propósito**. En Railway, `latest` no da
actualizaciones automáticas (solo hace pull al redesplegar), pero sí provoca
saltos de versión no planificados en cualquier redeploy accidental.

Además, las migraciones de esquema de SQLite son **hacia adelante**: si una
actualización rompe algo, volver al tag anterior no lo arregla, porque la base ya
está migrada. Hay que restaurar de backup.

**Rutina:**

1. Suscríbete a los releases de Vaultwarden (Watch → Releases only)
2. Lanza un backup y confirma que subió
3. Lee las notas de la release
4. Cambia el tag en el `Dockerfile` → commit → deploy
5. Entra por web y comprueba que la bóveda carga

---

## Antes de darlo por terminado

**Un solo Owner de la organización es un punto único de fallo sin arreglo.** Si
pierdes tu master password o quedas incapacitado, nadie puede entrar: Vaultwarden
no tiene recuperación de cuenta, y los backups no ayudan porque siguen
necesitando tu master password.

Elige una de las dos:

- **Segundo Owner** en la organización
- **Sobre sellado** con la master password y la clave age privada, custodiado
  fuera de la empresa

Es lo único del montaje que no se puede resolver después.

---

## Diagnóstico rápido

| Síntoma | Causa |
|---|---|
| `DOMAIN variable needs to contain the protocol` | Falta `https://` en `DOMAIN` |
| `403 AccessDenied` en rclone | *Token Value* en vez de *Access Key ID*, o falta `no_check_bucket` |
| `operation error S3: CreateBucket` | Falta `no_check_bucket = true` |
| `501 Not Implemented` con `rclone rcat` | R2 no soporta subida por streaming. El script usa `copyto` |
| `Config file not found - using defaults` | Ruido informativo de rclone, no es un error |
| SMTP timeout a cualquier host | SMTP saliente bloqueado en Hobby |
| `Insecure URL not allowed` en la web vault | El servidor se sirve por `http://` |
| Railpack no sabe cómo construir | Nombre de archivo mal (`DOCKERFILE`, `package.js`…) |
| El contenedor no arranca tras editar un `.sh` | Finales de línea CRLF. Añade `*.sh text eol=lf` a `.gitattributes` |
