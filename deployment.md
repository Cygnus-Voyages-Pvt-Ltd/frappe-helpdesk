# Deploying Frappe Helpdesk on Railway

Step-by-step guide for running Helpdesk as a single Railway service, using the
`Dockerfile` and `docker/railway/` scaffolding in this repo.

For the reference material behind these steps — every environment variable, the
build arguments, and what each file does — see
[`docker/railway/README.md`](docker/railway/README.md).

## What gets deployed

Railway gives a service exactly one public port, so everything the app needs
runs in one container under supervisord:

```
                    Railway edge (TLS)
                            │
                            ▼
        ┌─────────────── nginx (:$PORT) ───────────────┐
        │                                              │
   /assets, /files                            /socket.io      everything else
   from sites/                                     │                 │
                                                   ▼                 ▼
                                        node socketio (:9000)  gunicorn (:8000)
        ─────────────────────────────────────────────────────────────────────
        also in the container: RQ worker · scheduler · (optional) Redis
```

MariaDB is a separate Railway service. Redis is optional — attach one, or let
the container run its own.

## Prerequisites

- A Railway account and a project.
- This branch (with `Dockerfile`, `railway.json`, `.dockerignore` and
  `docker/railway/`) pushed to GitHub.

## Step 1 — Push the branch

Railway deploys from a GitHub branch. Make sure the deployment files are on the
branch you intend to deploy.

## Step 2 — Create the MariaDB service

**New → Docker Image → `mariadb:11`**, then:

- Add a volume mounted at `/var/lib/mysql`.
- Set `MARIADB_ROOT_PASSWORD` to a password you choose.
- Set the custom start command:

  ```
  docker-entrypoint.sh mariadbd --bind-address='*' --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --skip-character-set-client-handshake
  ```

`--bind-address='*'` listens on IPv4 **and** IPv6. Railway's private network is
IPv6-only, so the server has to listen on `::` — but `--bind-address=::` on its
own is IPv6-*only* and refuses every IPv4 client, which is easy to mistake for a
credentials problem.

Frappe needs `CREATE DATABASE` and `CREATE USER`, so it connects as `root`.

## Step 3 — (Optional) Add Redis

**New → Database → Redis.** The app picks up `REDIS_PRIVATE_URL` on its own and
gives cache and queue separate Redis databases (`/0` and `/1`) so clearing the
cache can never drop queued background jobs.

Skip this step and the container starts its own Redis on `127.0.0.1:6379`. That
works fine, with one caveat: queued jobs are lost when the container restarts.

## Step 4 — Create the Helpdesk service

**New → GitHub Repo →** this repository, and pick the branch from step 1.
Railway reads `railway.json` and uses the Dockerfile builder, so there is nothing
to configure for the build itself.

## Step 5 — Generate the public domain *before* the first deploy

**Settings → Networking → Generate Domain.**

Do this first. The entrypoint names the frappe site after `RAILWAY_PUBLIC_DOMAIN`,
so generating the domain up front means the site name matches the host browsers
actually use. Without it the site is created as `helpdesk.localhost` — still
functional, because nginx sets `X-Frappe-Site-Name` and `default_site` is
configured, but less obvious to work with later.

## Step 6 — Add a volume

Mount a volume at:

```
/home/frappe/frappe-bench/sites
```

This holds `site_config.json` (including the database credentials and the
encryption key) and everything users upload. Without it, every redeploy creates
a brand-new site and orphans the old database.

The volume starts empty and hides the image's `sites/` directory, so the
entrypoint re-seeds `apps.txt` and the built `assets/` from
`/opt/frappe/sites-template` on every boot.

## Step 7 — Set the variables

| Variable | Value |
| --- | --- |
| `PORT` | `8080` |
| `DB_HOST` | `${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}` |
| `DB_ROOT_PASSWORD` | `${{MariaDB.MARIADB_ROOT_PASSWORD}}` |
| `ADMIN_PASSWORD` | A password you choose for the `Administrator` user |
| `REDIS_URL` | `${{Redis.REDIS_PRIVATE_URL}}` — only if you did step 3 |

Use Railway's `${{Service.VAR}}` reference syntax so the values track the
database service rather than being copied by hand.

If `ADMIN_PASSWORD` is left unset, the entrypoint generates one and prints it in
the deploy logs exactly once, on the deploy that creates the site.

`docker/railway/README.md` lists the optional variables (`SITE_NAME`, `SITE_URL`,
`GUNICORN_WORKERS`, `WORKER_QUEUES`, `CLIENT_MAX_BODY_SIZE`,
`REDIRECT_ROOT_TO_HELPDESK`, `SKIP_MIGRATE`, `FORCE_NEW_SITE`, `ENCRYPTION_KEY`).

## Step 8 — Deploy

The first deploy runs `bench new-site --install-app telephony --install-app helpdesk`,
which takes a few minutes. Nothing answers on `$PORT` until it finishes — that is
why `railway.json` sets `healthcheckTimeout: 900`.

Watch the deploy logs for:

```
[helpdesk] Creating site <your-domain> (this takes a few minutes on first deploy)
[helpdesk] Helpdesk is starting on https://<your-domain>/helpdesk
```

Then open `https://<your-domain>/helpdesk` and sign in as `Administrator` with
`ADMIN_PASSWORD`. `/` redirects to `/helpdesk`; set
`REDIRECT_ROOT_TO_HELPDESK=0` if you would rather serve the frappe website there.

## Redeploys

Later deploys take the migrate path instead:

```
[helpdesk] Using existing site <site>
[helpdesk] Running bench migrate on <site>
```

The site recorded in `sites/currentsite.txt` always wins over the `SITE_NAME`
variable, so changing or removing the Railway domain later will not orphan the
data. A failing migration deliberately aborts the boot rather than serving a
half-migrated site.

## Running bench commands

Any command other than `supervisord` runs inside the bench as the `frappe` user:

```bash
railway run --service helpdesk -- bench --site <site> console
railway run --service helpdesk -- bench --site <site> set-config mute_emails 0
```

## After the first deploy

- **Email** — outgoing and incoming mail are not configured. Add an Email Account
  in the Helpdesk UI once you are logged in.
- **Sizing** — gunicorn defaults to 2 workers × 4 threads, which wants roughly
  2 GB of memory alongside the worker, scheduler and socketio processes. Tune
  with `GUNICORN_WORKERS` / `GUNICORN_THREADS`.
- **Custom domain** — add it in Railway's networking settings. It works without
  recreating the site: nginx sets `X-Frappe-Site-Name` for every request. Point
  `SITE_URL` at the custom domain so generated links and the socket.io origin
  use it.

## Troubleshooting

**`MariaDB at <host>:3306 did not come up`** — the database is not reachable on
the private network. Check `--bind-address='*'` from step 2, and that `DB_HOST`
references the database's `RAILWAY_PRIVATE_DOMAIN`. The entrypoint waits about
five minutes (`WAIT_ATTEMPTS`, 2s apart) before giving up.

**Health check fails on the very first deploy** — site creation is still
running. Confirm in the logs; raise `healthcheckTimeout` in `railway.json` if
your instance is slow.

**Redirects land on `:8080`** — a proxy in front of nginx is rewriting
`Location`. nginx itself is configured with `absolute_redirect off`, so it emits
relative redirects only.

**Assets 404 after a redeploy** — the volume is mounted somewhere other than
`/home/frappe/frappe-bench/sites`, so the entrypoint cannot re-seed `assets/`.

**Site created with the wrong name** — the domain did not exist yet at first
deploy. Either keep it (everything still works) or delete the volume and
redeploy to recreate the site from scratch.

## Build arguments

The image pins `PYTHON_VERSION=3.14`, `NODE_MAJOR=24` (matching CI),
`FRAPPE_BRANCH=develop` — frappe 16-dev, which is what `pyproject.toml` requires
— and `TELEPHONY_BRANCH` (empty, meaning the repository default branch).
Override them in Railway's build settings if you need a different combination.
