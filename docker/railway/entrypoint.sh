#!/usr/bin/env bash
#
# Railway entrypoint for the single-container Frappe Helpdesk image.
#
#   1. re-seed sites/ (Railway mounts an empty volume over it on first boot)
#   2. resolve MariaDB / Redis connection details from Railway service variables
#   3. write common_site_config.json
#   4. create the site on first boot, run `bench migrate` on every later boot
#   5. render nginx.conf for $PORT and hand over to supervisord
#
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITES="${BENCH}/sites"
TEMPLATE=/opt/frappe/sites-template
APP_USER=frappe

log() { printf '\n\033[1;34m[helpdesk]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[helpdesk] %s\033[0m\n' "$*" >&2; exit 1; }

run_bench() { (cd "${BENCH}" && gosu "${APP_USER}" bench "$@"); }

# ---------------------------------------------------------------------------
# 1. sites/ directory
# ---------------------------------------------------------------------------
seed_sites_dir() {
    log "Preparing ${SITES}"
    mkdir -p "${SITES}"

    shopt -s dotglob nullglob
    for item in "${TEMPLATE}"/*; do
        name="$(basename "${item}")"
        [ -e "${SITES}/${name}" ] || cp -a "${item}" "${SITES}/${name}"
    done
    shopt -u dotglob nullglob

    # These two are build artefacts, never user data — always take the image's copy.
    rm -rf "${SITES}/assets"
    cp -a "${TEMPLATE}/assets" "${SITES}/assets"
    [ -f "${TEMPLATE}/apps.txt" ] && cp -a "${TEMPLATE}/apps.txt" "${SITES}/apps.txt"

    chown -R "${APP_USER}:${APP_USER}" "${SITES}"
}

# ---------------------------------------------------------------------------
# 2. service connection details
# ---------------------------------------------------------------------------
url_part() {
    # url_part <url> <hostname|port|username|password|path>
    python3 - "$1" "$2" <<'PY'
import sys
from urllib.parse import urlparse, unquote

url, part = sys.argv[1], sys.argv[2]
parsed = urlparse(url)
value = {
    "hostname": parsed.hostname,
    "port": parsed.port,
    "username": parsed.username,
    "password": parsed.password,
    "path": parsed.path.lstrip("/"),
}.get(part)
print(unquote(str(value)) if value is not None else "")
PY
}

resolve_database() {
    local url="${DB_URL:-${MYSQL_URL:-${MYSQL_PRIVATE_URL:-${MARIADB_URL:-${DATABASE_URL:-}}}}}"

    if [ -n "${url}" ]; then
        DB_HOST="${DB_HOST:-$(url_part "${url}" hostname)}"
        DB_PORT="${DB_PORT:-$(url_part "${url}" port)}"
        DB_ROOT_USER="${DB_ROOT_USER:-$(url_part "${url}" username)}"
        DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(url_part "${url}" password)}"
    fi

    # Railway's MySQL/MariaDB service also exports these directly.
    DB_HOST="${DB_HOST:-${MYSQLHOST:-${MARIADBHOST:-}}}"
    DB_PORT="${DB_PORT:-${MYSQLPORT:-${MARIADBPORT:-3306}}}"
    DB_ROOT_USER="${DB_ROOT_USER:-${MYSQLUSER:-${MARIADBUSER:-root}}}"
    DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-${MYSQLPASSWORD:-${MARIADBPASSWORD:-}}}}}"

    [ -n "${DB_HOST}" ] || die "No database host. Add a MariaDB service and reference its variables (see docker/railway/README.md)."
    [ -n "${DB_ROOT_PASSWORD}" ] || die "No database root password. Set DB_ROOT_PASSWORD (or reference MYSQL_ROOT_PASSWORD from the database service)."

    export DB_HOST DB_PORT DB_ROOT_USER DB_ROOT_PASSWORD
    log "Database: ${DB_ROOT_USER}@${DB_HOST}:${DB_PORT}"
}

resolve_redis() {
    local base="${REDIS_PRIVATE_URL:-${REDIS_URL:-}}"

    if [ -z "${base}" ]; then
        EMBEDDED_REDIS=true
        base="redis://127.0.0.1:6379"
        log "No Redis service found — using the Redis bundled in this container."
    else
        EMBEDDED_REDIS=false
        log "Redis: ${base%%:*}://***@$(url_part "${base}" hostname):$(url_part "${base}" port)"
    fi

    # Strip any trailing database index, then give cache and queue their own db
    # so that a cache flush can never wipe queued background jobs.
    base="${base%/}"
    base="$(printf '%s' "${base}" | sed -E 's#/[0-9]+$##')"

    REDIS_CACHE_URL="${REDIS_CACHE_URL:-${base}/0}"
    REDIS_QUEUE_URL="${REDIS_QUEUE_URL:-${base}/1}"
    export EMBEDDED_REDIS REDIS_CACHE_URL REDIS_QUEUE_URL
}

wait_for() {
    # wait_for <host> <port> <label>
    local host="$1" port="$2" label="$3" attempt=0
    log "Waiting for ${label} at ${host}:${port}"
    until python3 -c "
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3).close()
except OSError:
    raise SystemExit(1)
" "${host}" "${port}"; do
        attempt=$((attempt + 1))
        [ "${attempt}" -lt "${WAIT_ATTEMPTS:-150}" ] \
            || die "${label} at ${host}:${port} did not come up."
        [ $((attempt % 15)) -eq 0 ] && log "still waiting for ${label} (${attempt} attempts)"
        sleep 2
    done
}

# ---------------------------------------------------------------------------
# 3. common_site_config.json
# ---------------------------------------------------------------------------
write_common_site_config() {
    log "Writing sites/common_site_config.json"
    gosu "${APP_USER}" python3 - "${SITES}/common_site_config.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]

try:
    with open(path) as f:
        config = json.load(f)
except (OSError, ValueError):
    config = {}

config.update(
    {
        "db_type": "mariadb",
        "db_host": os.environ["DB_HOST"],
        "db_port": int(os.environ.get("DB_PORT") or 3306),
        "redis_cache": os.environ["REDIS_CACHE_URL"],
        "redis_queue": os.environ["REDIS_QUEUE_URL"],
        # Removed in newer frappe, harmless if unused.
        "redis_socketio": os.environ["REDIS_QUEUE_URL"],
        "socketio_port": 9000,
        "webserver_port": 8000,
        "serve_default_site": True,
        "default_site": os.environ["SITE_NAME"],
        "developer_mode": 0,
        "maintenance_mode": 0,
        "background_workers": int(os.environ.get("BACKGROUND_WORKERS") or 1),
        "gunicorn_workers": int(os.environ.get("GUNICORN_WORKERS") or 2),
        "restart_supervisor_on_update": False,
        "restart_systemd_on_update": False,
        "live_reload": False,
        "file_watcher_port": 6787,
    }
)

if os.environ.get("ENCRYPTION_KEY"):
    config["encryption_key"] = os.environ["ENCRYPTION_KEY"]

with open(path, "w") as f:
    json.dump(config, f, indent=1, sort_keys=True)
PY
}

# ---------------------------------------------------------------------------
# 4. site
# ---------------------------------------------------------------------------
resolve_site_name() {
    # An existing site on the volume always wins, so that a change of Railway
    # domain never orphans the data.
    if [ -f "${SITES}/currentsite.txt" ]; then
        local existing
        existing="$(tr -d '[:space:]' < "${SITES}/currentsite.txt")"
        if [ -n "${existing}" ] && [ -f "${SITES}/${existing}/site_config.json" ]; then
            SITE_NAME="${existing}"
            export SITE_NAME
            log "Using existing site ${SITE_NAME}"
            return
        fi
    fi

    SITE_NAME="${SITE_NAME:-${RAILWAY_PUBLIC_DOMAIN:-helpdesk.localhost}}"
    export SITE_NAME
    log "Site name: ${SITE_NAME}"
}

create_or_migrate_site() {
    if [ -f "${SITES}/${SITE_NAME}/site_config.json" ]; then
        if [ "${SKIP_MIGRATE:-0}" = "1" ]; then
            log "SKIP_MIGRATE=1 — not running bench migrate"
        else
            log "Running bench migrate on ${SITE_NAME}"
            run_bench --site "${SITE_NAME}" migrate
        fi
    else
        if [ -z "${ADMIN_PASSWORD:-}" ]; then
            ADMIN_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))')"
            log "ADMIN_PASSWORD was not set. Generated one for the Administrator user:"
            printf '\n    %s\n\n' "${ADMIN_PASSWORD}"
            log "Save it now — it is only printed on the deploy that creates the site."
        fi

        local flags=(
            --admin-password "${ADMIN_PASSWORD}"
            --db-root-username "${DB_ROOT_USER}"
            --db-root-password "${DB_ROOT_PASSWORD}"
            --install-app telephony
            --install-app helpdesk
            --set-default
        )

        # The app connects from a different host than the database container, so
        # the site's db user has to be granted for '%'.
        if run_bench new-site --help 2>/dev/null | grep -q -- '--mariadb-user-host-login-scope'; then
            flags+=(--mariadb-user-host-login-scope '%')
        else
            flags+=(--no-mariadb-socket)
        fi

        [ "${FORCE_NEW_SITE:-0}" = "1" ] && flags+=(--force)

        log "Creating site ${SITE_NAME} (this takes a few minutes on first deploy)"
        run_bench new-site "${SITE_NAME}" "${flags[@]}"
    fi

    echo "${SITE_NAME}" > "${SITES}/currentsite.txt"
    chown "${APP_USER}:${APP_USER}" "${SITES}/currentsite.txt"

    run_bench --site "${SITE_NAME}" set-config host_name "${SITE_URL}"
    run_bench --site "${SITE_NAME}" enable-scheduler >/dev/null 2>&1 \
        || run_bench --site "${SITE_NAME}" scheduler enable >/dev/null 2>&1 \
        || true
    run_bench --site "${SITE_NAME}" clear-cache >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 5. nginx + supervisord
# ---------------------------------------------------------------------------
render_nginx_conf() {
    log "Rendering nginx config for port ${PORT}"
    mkdir -p /tmp/nginx
    if [ "${REDIRECT_ROOT_TO_HELPDESK:-1}" = "1" ]; then
        export ROOT_LOCATION="return 302 /helpdesk;"
    else
        export ROOT_LOCATION=""
    fi
    export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"
    envsubst '${PORT} ${SITE_NAME} ${SITE_URL} ${ROOT_LOCATION} ${CLIENT_MAX_BODY_SIZE}' \
        < /opt/frappe/nginx.conf.template > /etc/nginx/nginx.conf
    nginx -t
}

main() {
    export PORT="${PORT:-8080}"
    export GUNICORN_WORKERS="${GUNICORN_WORKERS:-2}"
    export GUNICORN_THREADS="${GUNICORN_THREADS:-4}"
    export GUNICORN_TIMEOUT="${GUNICORN_TIMEOUT:-120}"
    export WORKER_QUEUES="${WORKER_QUEUES:-short,default,long}"

    seed_sites_dir
    resolve_site_name

    export SITE_URL="${SITE_URL:-https://${RAILWAY_PUBLIC_DOMAIN:-${SITE_NAME}}}"

    resolve_database
    resolve_redis

    if [ "${EMBEDDED_REDIS}" = "true" ]; then
        redis-server --bind 127.0.0.1 --port 6379 --save '' --appendonly no --daemonize yes
        wait_for 127.0.0.1 6379 "embedded Redis"
    else
        wait_for "$(url_part "${REDIS_CACHE_URL}" hostname)" "$(url_part "${REDIS_CACHE_URL}" port)" "Redis"
    fi

    wait_for "${DB_HOST}" "${DB_PORT}" "MariaDB"

    write_common_site_config
    create_or_migrate_site
    render_nginx_conf

    if [ "${EMBEDDED_REDIS}" = "true" ]; then
        # Hand the port back to supervisord, which owns Redis from here on.
        redis-cli -h 127.0.0.1 -p 6379 shutdown nosave >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            python3 -c "
import socket, sys
try:
    socket.create_connection(('127.0.0.1', 6379), timeout=1).close()
except OSError:
    raise SystemExit(0)
raise SystemExit(1)
" && break
            sleep 0.5
        done
    fi

    log "Helpdesk is starting on ${SITE_URL}/helpdesk"
    exec /usr/bin/supervisord -c /opt/frappe/supervisord.conf -n
}

if [ "${1:-supervisord}" = "supervisord" ]; then
    main
else
    # Anything else is treated as a one-off command in the bench, e.g.
    #   railway run -- bench --site <site> add-system-manager ...
    seed_sites_dir
    cd "${BENCH}"
    exec gosu "${APP_USER}" "$@"
fi
