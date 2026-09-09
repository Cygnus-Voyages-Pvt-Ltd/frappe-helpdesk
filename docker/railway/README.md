# Deploying Helpdesk on Railway

This directory holds everything the root `Dockerfile` needs to run Helpdesk as a
**single Railway service**: nginx on `$PORT` in front of gunicorn and the
socket.io node server, with the RQ workers and the scheduler managed by
supervisord in the same container.

| File | Purpose |
| --- | --- |
| `../../Dockerfile` | Builds `frappe-bench` with frappe + telephony + helpdesk and compiles the desk SPA |
| `../../railway.json` | Tells Railway to use the Dockerfile and where the health check lives |
| `entrypoint.sh` | Seeds `sites/`, resolves service variables, creates/migrates the site, renders nginx.conf |
| `nginx.conf.template` | nginx config, rendered with `envsubst` at boot |
| `supervisord.conf` | Process table: nginx, gunicorn, socketio, worker, scheduler (+ optional bundled Redis) |

## Services to create

1. **MariaDB** — `mariadb:11` deployed from a Docker image, with a volume on
   `/var/lib/mysql` and a start command that binds on IPv6 (Railway's private
   network is IPv6-only):

   ```
   docker-entrypoint.sh mariadbd --bind-address='*' \
     --character-set-server=utf8mb4 \
     --collation-server=utf8mb4_unicode_ci \
     --skip-character-set-client-handshake
   ```

   `--bind-address='*'` listens on IPv4 *and* IPv6; `--bind-address=::` alone is
   IPv6-only, which is enough for Railway's private network but breaks anything
   that reaches the database over IPv4.

2. **Redis** — optional. Attach one from the Railway catalogue and the app picks
   up `REDIS_PRIVATE_URL` automatically. With no Redis service, the container
   starts its own on `127.0.0.1:6379` (fine to start with; queued jobs are lost
   on restart).

3. **Helpdesk** — this repository. Add a volume mounted at
   `/home/frappe/frappe-bench/sites` so the site config, encryption key and
   uploaded files survive redeploys.

## Variables

Required:

| Variable | Notes |
| --- | --- |
| `DB_HOST` | e.g. `${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}` |
| `DB_ROOT_PASSWORD` | e.g. `${{MariaDB.MARIADB_ROOT_PASSWORD}}` |
| `ADMIN_PASSWORD` | Password for the `Administrator` user. Generated and printed once if omitted |
| `PORT` | `8080` |

`DB_URL` / `MYSQL_URL` / `DATABASE_URL` are parsed as an alternative to
`DB_HOST` + `DB_ROOT_*`, and Railway's `MYSQLHOST` / `MYSQL_ROOT_PASSWORD` style
variables are picked up too.

Optional:

| Variable | Default | Notes |
| --- | --- | --- |
| `SITE_NAME` | `$RAILWAY_PUBLIC_DOMAIN` | Only used when creating the site; afterwards `sites/currentsite.txt` wins |
| `SITE_URL` | `https://$RAILWAY_PUBLIC_DOMAIN` | Used for `host_name` and as the socket.io `Origin` |
| `GUNICORN_WORKERS` | `2` | |
| `GUNICORN_THREADS` | `4` | |
| `GUNICORN_TIMEOUT` | `120` | |
| `WORKER_QUEUES` | `short,default,long` | |
| `BACKGROUND_WORKERS` | `1` | |
| `CLIENT_MAX_BODY_SIZE` | `50m` | Upload limit in nginx |
| `REDIRECT_ROOT_TO_HELPDESK` | `1` | `/` → `/helpdesk`; set `0` to serve the frappe website at `/` |
| `SKIP_MIGRATE` | `0` | Skip `bench migrate` on boot |
| `FORCE_NEW_SITE` | `0` | Pass `--force` to `bench new-site` (drops an existing database) |
| `ENCRYPTION_KEY` | — | Pin the key instead of letting the site generate one |

## Build arguments

`PYTHON_VERSION` (3.14), `NODE_MAJOR` (24), `FRAPPE_BRANCH` (`develop`, i.e.
frappe 16-dev, which is what `pyproject.toml` pins) and `TELEPHONY_BRANCH`
(empty = repository default).

## First boot

The entrypoint creates the site before supervisord starts, so nothing answers on
`$PORT` for the few minutes `bench new-site --install-app helpdesk` takes —
hence `healthcheckTimeout: 900` in `railway.json`. Watch the deploy logs; the
generated Administrator password (when `ADMIN_PASSWORD` is unset) is printed
there exactly once.

## Running bench commands

Any command other than `supervisord` is executed inside the bench as the
`frappe` user, so a one-off shell works:

```bash
railway run --service helpdesk -- bench --site <site> console
```
