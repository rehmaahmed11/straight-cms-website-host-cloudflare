#!/data/data/com.termux/files/usr/bin/bash
# =====================================================================
#  AHMED WEB PANEL  (Termux edition, v2 — AMS CMS)
#  Multi-site manager: Nginx + Node.js + the Edge CMS app in this repo.
#  No root needed. Run inside Termux:   bash ahmed-panel-termux.sh
#
#  v1 was "nginx + PHP-FPM + MariaDB + WordPress".
#  v2 replaces WordPress with the repo app, and that removes a whole
#  layer instead of adding one:
#
#    php-fpm      -> gone. The app is TypeScript on Hono, it has no PHP.
#    mariadb      -> gone. Each site owns one SQLite file (data/cms.sqlite).
#    wp-config.php-> gone. Per-site env file: PORT/HOST/DATA_DIR/TRUST_PROXY
#                    /DB_PASSWORD, and the app refuses to boot a data folder
#                    whose DB password it cannot match.
#    the 5-minute WP cron -> gone. The app publishes scheduled posts and runs
#                    its own migrations on an in-process 60s tick.
#    "download WordPress per site" -> kept: the app is built ONCE into a single
#                    ~1 MB dist/server.mjs and every site runs that one file.
#
#  nginx stays, and it is now a reverse proxy (fastcgi_params -> proxy_params)
#  instead of a FastCGI front end. It MUST forward Host / X-Forwarded-Proto /
#  X-Forwarded-For, because the app runs with TRUST_PROXY=1.
#
#  Per-site isolation model: 1 site = 1 node process = 1 port on 127.0.0.1
#  = 1 folder. The app is single-tenant by construction (its install lock,
#  admin slug and session secret are global keys, and 184 queries hard-code
#  site_id=1), so fanning out instances is the ONLY correct tenancy shape.
# =====================================================================

set -u -o pipefail

PANEL_NAME="AHMED WEB PANEL"
PANEL_VERSION="v2 Termux (AMS CMS edition)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

DATA="$HOME/.ahmed-panel"
SITES_DIR="$HOME/ahmed-sites"
BACKUP_DIR="$HOME/ahmed-backups"
APP_CACHE="$DATA/app"                       # the ONE built server.mjs, reused by every site
BUILD_DIR="$DATA/build"                    # where the repo is cloned to build it
REG_FILE="$DATA/sites.db"                  # name|primary_domain|root|data_dir|port|admin_slug
ENV_DIR="$DATA/env"                        # per-site env files (0600)

# ---- where the app comes from. APP_SOURCE=git builds it on the phone;
# ---- APP_SOURCE=url just downloads a prebuilt server.mjs (no npm, no esbuild,
# ---- recommended for a 3 GB phone: a 40 MB download beats a 400 MB node_modules).
APP_SOURCE="${APP_SOURCE:-git}"                                  # git | url
APP_REPO="${APP_REPO:-https://github.com/rizwanahmedsora9-pixel/ams-builds.online.git}"
APP_REF="${APP_REF:-main}"                                       # tag, branch or commit
APP_BUNDLE_URL="${APP_BUNDLE_URL:-}"                             # e.g. https://github.com/you/ams-builds.online/releases/download/v0.9.0/server.mjs
APP_FILE="$APP_CACHE/server.mjs"
APP_META="$APP_CACHE/version.txt"
SITE_PORT_BASE=8090                        # per-site loopback ports start here
MIN_NODE_MAJOR=22
MIN_NODE_MINOR=13

HTTP_PORT=8080                             # Android blocks port 80 without root
NGX_DIR="$DATA/nginx"
NGX_CONF="$NGX_DIR/nginx.conf"
NGX_SITES="$NGX_DIR/sites"
NGX_PROXY="$NGX_DIR/proxy_params"
NGX_PID="$DATA/run/nginx.pid"
NGX_ERR="$DATA/logs/nginx-error.log"

# ---------- colors ----------
R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; C=$'\e[1;36m'; W=$'\e[1;37m'; D=$'\e[2m'; N=$'\e[0m'

ok()   { echo -e "${G}[ OK ]${N} $*"; }
err()  { echo -e "${R}[ERR ]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
info() { echo -e "${C}[INFO]${N} $*"; }
pause(){ echo; read -rp "${D}Press Enter to continue...${N}" _ || true; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

banner() {
  clear 2>/dev/null || true
  echo -e "${C}"
  echo "  ┌──────────────────────────────────────┐"
  printf "  │  %-36s│\n" "$PANEL_NAME"
  printf "  │  %-36s│\n" "$PANEL_VERSION"
  echo "  └──────────────────────────────────────┘"
  echo -e "${N}"
}

require_termux() {
  if [[ -z ${TERMUX_VERSION:-} && ! -d $PREFIX ]]; then
    err "This panel is for Termux only (looked for $PREFIX)."
    exit 1
  fi
  have_cmd pkg || { err "'pkg' not found. Are you inside Termux?"; exit 1; }
}

init_dirs() {
  mkdir -p "$DATA"/{run,logs,tmp} "$DATA/registry" "$ENV_DIR" "$NGX_SITES" \
           "$SITES_DIR" "$BACKUP_DIR" "$APP_CACHE"
  touch "$REG_FILE"
  chmod 700 "$DATA" "$ENV_DIR" 2>/dev/null || true
}

rand() { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-24}"; }
sha()  { sha256sum "$1" 2>/dev/null | cut -c1-16; }
valid_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
valid_name()   { [[ "$1" =~ ^[a-z][a-z0-9_]{1,19}$ ]]; }
valid_slug()   { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{2,40}$ ]]; }

site_exists()  { grep -q "^$1|" "$REG_FILE" 2>/dev/null; }
domain_in_use(){ grep -rqsxF -- "$1" "$DATA"/*.domains 2>/dev/null; }
get_field()    { grep "^$1|" "$REG_FILE" 2>/dev/null | grep -v '^#' | cut -d'|' -f"$2" | head -n1; }
domains_of()   { if [[ -f $DATA/$1.domains ]]; then tr '\n' ' ' < "$DATA/$1.domains"; fi; }
site_root()    { get_field "$1" 3; }
site_data()    { get_field "$1" 4; }
site_port()    { get_field "$1" 5; }
site_slug()    { get_field "$1" 6; }

# ---------------------------------------------------------------------
#  Node.js: the only runtime requirement, and it has a hard floor
#  The app imports DatabaseSync from 'node:sqlite', which needs Node 22.13+.
#  Ubuntu/Debian's nodejs is 18/20, so Termux's `pkg install nodejs` is what
#  saves you here; older or hand-built nodes have to be told.
# ---------------------------------------------------------------------
NODE_FLAGS="--disable-warning=ExperimentalWarning"

node_installed() { have_cmd node; }

node_version_ok() {
  node_installed || return 1
  local v major minor
  v=$(node -v 2>/dev/null); v=${v#v}
  major=${v%%.*}
  minor=$(printf '%s' "$v" | cut -d. -f2)
  [[ $major =~ ^[0-9]+$ ]] || return 1
  [[ $minor =~ ^[0-9]+$ ]] || minor=0
  (( major > MIN_NODE_MAJOR || (major == MIN_NODE_MAJOR && minor >= MIN_NODE_MINOR) ))
}

# Does this node expose node:sqlite at all, and does it need the old flag?
node_sqlite_setup() {
  NODE_FLAGS="--disable-warning=ExperimentalWarning"
  node_installed || return 1
  if node --input-type=module -e "await import('node:sqlite')" >/dev/null 2>&1; then return 0; fi
  if node --experimental-sqlite --input-type=module -e "await import('node:sqlite')" >/dev/null 2>&1; then
    NODE_FLAGS="--experimental-sqlite --disable-warning=ExperimentalWarning"
    return 0
  fi
  return 1
}

node_label() { local v; v=$(node -v 2>/dev/null) || v="missing"; printf '%s' "$v"; }

any_site_down() {
  local n
  for n in $(all_sites); do site_running "$n" || return 0; done
  return 1
}

# ---------------------------------------------------------------------
#  The app "template": one built server.mjs, reused by every site.
#  (v1 cached a WordPress tarball; the shape of the idea is the same, the
#  artifact is one file instead of 60 MB of PHP.)
# ---------------------------------------------------------------------
app_ready() { [[ -s $APP_FILE ]]; }

app_version() {
  if [[ -f $APP_META ]]; then cat "$APP_META"; else printf 'unknown'; fi
}

app_download() { # -> writes $APP_FILE from APP_BUNDLE_URL
  [[ -n $APP_BUNDLE_URL ]] || { err "APP_SOURCE=url needs APP_BUNDLE_URL set to a server.mjs."; return 1; }
  local tmp; tmp=$(mktemp "$APP_CACHE/.srv.XXXXXX")
  info "Downloading prebuilt bundle..."
  if ! curl -fsSL --max-time 300 "$APP_BUNDLE_URL" -o "$tmp"; then
    err "Download failed (check internet)."; rm -f "$tmp"; return 1
  fi
  [[ $(wc -c <"$tmp") -gt 200000 ]] || { err "That file is too small to be the bundle."; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$APP_FILE"
  printf '%s  (url, sha256 %s)' "${APP_REF:-prebuilt}" "$(sha "$APP_FILE")" > "$APP_META"
}

app_build() { # clones the repo, builds ONLY dist/server.mjs, caches it
  have_cmd git || { err "git is missing. Run option 5, or set APP_SOURCE=url."; return 1; }
  info "Cloning $APP_REPO ($APP_REF) — one time only..."
  rm -rf "$BUILD_DIR/repo"
  mkdir -p "$BUILD_DIR"
  local clone=(git clone --depth 1)
  [[ -n $APP_REF ]] && clone+=(--branch "$APP_REF")
  if ! "${clone[@]}" "$APP_REPO" "$BUILD_DIR/repo" >/dev/null 2>&1; then
    # a commit SHA is not a --branch; fall back to a full clone + checkout
    if ! git clone "$APP_REPO" "$BUILD_DIR/repo" >/dev/null 2>&1; then
      err "git clone failed (network, or the repo is private)."; return 1
    fi
    ( cd "$BUILD_DIR/repo" && git checkout -q "$APP_REF" ) || { err "checkout $APP_REF failed"; return 1; }
  fi
  local repo="$BUILD_DIR/repo"

  info "Installing npm packages (this is the slow part on a phone)..."
  ( cd "$repo" && { npm ci --no-audit --no-fund || npm install --no-audit --no-fund; } ) \
    || { err "npm install failed. If it was disk space, use APP_SOURCE=url."; return 1; }

  # esbuild ships its real binary as an optionalDependency (@esbuild/<os>-<arch>).
  # If node_modules was installed with --omit=optional (the trick the README
  # suggests on Android to skip wrangler) that binary is missing and esbuild
  # throws. Re-add exactly the one package it needs.
  if ! ( cd "$repo" && ./node_modules/.bin/esbuild --version >/dev/null 2>&1 ); then
    local pkg
    pkg="@esbuild/$(node -p 'process.platform')-$(node -p 'process.arch')"
    info "esbuild platform binary missing — installing $pkg"
    ( cd "$repo" && npm install --no-save --no-audit --no-fund "$pkg" >/dev/null 2>&1 ) \
      || { err "Could not install $pkg."; return 1; }
  fi

  info "Bundling the server into one file..."
  ( cd "$repo" && ./node_modules/.bin/esbuild src/node/server.ts \
      --bundle --platform=node --format=esm --target=node22 \
      --loader:.html=text --loader:.css=text --loader:.sql=text \
      --loader:.png=binary --loader:.jpg=binary --loader:.jpeg=binary \
      --loader:.webp=binary --loader:.avif=binary --loader:.ico=binary \
      --outfile="$APP_FILE" --log-level=warning ) \
    || { err "esbuild failed."; return 1; }
  [[ -s $APP_FILE ]] || { err "build produced no file."; return 1; }
  ( cd "$repo" && printf '%s  (%s @ %s, sha256 %s)' \
      "$(node -p "require('./package.json').version" 2>/dev/null || echo '?')" \
      "git $(git rev-parse --short HEAD 2>/dev/null)" "$APP_REF" "$(sha "$APP_FILE")" ) > "$APP_META" 2>/dev/null \
    || printf 'built %s' "$(date -u +%FT%TZ)" > "$APP_META"
  ok "Bundle saved: $(du -h "$APP_FILE" 2>/dev/null | cut -f1) (all sites share it)"
}

ensure_app() { # pass "force" to rebuild
  if app_ready && [[ ${1:-} != force ]]; then return 0; fi
  node_version_ok || { err "Node $(node_label) is too old — need >= ${MIN_NODE_MAJOR}.${MIN_NODE_MINOR} (option 5)."; return 1; }
  [[ $APP_SOURCE == url ]] && { app_download || return 1; } || { app_build || return 1; }
  smoke_test || { err "The new bundle did not boot — keeping you off it."; [[ $APP_SOURCE == url ]] && rm -f "$APP_FILE"; return 1; }
  ok "App ready: $(app_version)"
}

# Boot the bundle once on a throwaway data dir: proves the file works on THIS
# node before any live site is pointed at it.
smoke_test() {
  local tmp p code i=0 pid
  tmp=$(mktemp -d)
  p=$(( 20000 + RANDOM % 20000 ))
  ( PORT=$p HOST=127.0.0.1 DATA_DIR="$tmp/data" \
      exec node $NODE_FLAGS "$APP_FILE" ) >"$tmp/log" 2>&1 &
  pid=$!
  while (( i++ < 30 )); do
    sleep 0.5
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$p/api/health" 2>/dev/null) || true
    [[ ${code:-000} == 200 ]] && break
    kill -0 "$pid" 2>/dev/null || break
  done
  kill "$pid" 2>/dev/null || true; sleep 0.4; kill -9 "$pid" 2>/dev/null || true
  if [[ ${code:-} == 200 ]]; then rm -rf "$tmp"; return 0; fi
  err "smoke test failed:"; sed 's/^/     /' "$tmp/log" 2>/dev/null | head -n 12
  rm -rf "$tmp"; return 1
}

# ---------------------------------------------------------------------
#  Config generation
# ---------------------------------------------------------------------
write_base_configs() {
  local mime=""
  [[ -f $PREFIX/etc/nginx/mime.types ]] && mime="include $PREFIX/etc/nginx/mime.types;"
  cat > "$NGX_CONF" <<EOF
worker_processes 1;
pid $NGX_PID;
error_log $NGX_ERR;
events { worker_connections 512; }
http {
    $mime
    default_type application/octet-stream;
    access_log $DATA/logs/nginx-access.log;
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 25m;
    client_body_temp_path $DATA/tmp/body;
    proxy_temp_path       $DATA/tmp/proxy;
    fastcgi_temp_path     $DATA/tmp/fastcgi;
    uwsgi_temp_path       $DATA/tmp/uwsgi;
    scgi_temp_path        $DATA/tmp/scgi;
    include $NGX_SITES/*.conf;
}
EOF

  # The app runs with TRUST_PROXY=1, which makes these three headers part of
  # the security model, not cosmetics: without X-Forwarded-Proto every
  # permalink is built as http://, and without X-Forwarded-For the login rate
  # limiter (5 tries per IP per 15 min) counts your proxy, not the visitor.
  cat > "$NGX_PROXY" <<'EOF'
proxy_http_version 1.1;
proxy_pass_header Set-Cookie;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_connect_timeout 10s;
proxy_send_timeout    120s;
proxy_read_timeout    120s;
client_max_body_size  25m;
EOF
}

# Rendered from a template with @TOKENS@ so nothing about nginx's own $vars
# has to be escaped in a heredoc.
write_site_conf() { # name domains root port
  local f="$NGX_SITES/$1.conf.tmp"
  # "server_name ;" is an nginx syntax error, and a half-created site can ask
  # for exactly that: an empty domain list becomes the catch-all.
  local names=${2:-}
  [[ -z ${names// /} ]] && names="_"
  cat > "$f" <<'EOF'
# AHMED WEB PANEL — generated for @NAME@. Do not hand-edit: your next panel
# action rewrites this file. Domains, TLS and the upstream port all live in
# the panel's own state (~/.ahmed-panel).
server {
    listen @HTTPPORT@;
    server_name @DOMAINS@;

    # The app is only ever reachable on loopback, so nobody can skip nginx and
    # walk in with a forged X-Forwarded-Host / X-Forwarded-For.
    location / {
        proxy_pass http://127.0.0.1:@PORT@;
        include @PROXY@;
    }

    # Rendered pages are already cached inside the app (KV-style page cache
    # with a generation counter), so nginx must not add a second stale layer.
    add_header Cache-Control "public, max-age=0, must-revalidate" always;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
}
EOF
  sed -e "s#@NAME@#$1#" -e "s#@HTTPPORT@#$HTTP_PORT#" \
      -e "s#@DOMAINS@#$names#" -e "s#@PORT@#$4#" \
      -e "s#@PROXY@#$NGX_PROXY#" -e "s#@ROOT@#$3#" "$f" > "$NGX_SITES/$1.conf"
  rm -f "$f"
}

# ---------------------------------------------------------------------
#  Services (no systemd in Termux, so we manage processes ourselves)
# ---------------------------------------------------------------------
pid_alive() { [[ -f $1 ]] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
nginx_running() { pid_alive "$NGX_PID"; }
site_pid()  { printf '%s/run/%s.pid' "$DATA" "$1"; }
site_running() { pid_alive "$(site_pid "$1")"; }
nginx_cmd() { nginx -c "$NGX_CONF" -e "$NGX_ERR" "$@"; }

start_nginx() {
  nginx_running && return 0
  write_base_configs
  nginx_cmd -t >/dev/null 2>&1 || { err "nginx config invalid:"; nginx_cmd -t; return 1; }
  nginx_cmd && ok "nginx started (port $HTTP_PORT)" || err "nginx failed to start (see $NGX_ERR)"
}

start_site() { # name
  local name=$1 data port envf
  site_running "$name" && return 0
  app_ready || { err "The app bundle is not built yet. Run option 5 or 7."; return 1; }
  data=$(site_data "$name"); port=$(site_port "$name"); envf="$ENV_DIR/$name.env"
  [[ -f $envf ]] || { err "missing $envf — the site was half-created. Re-create it."; return 1; }
  [[ -n $port ]] || { err "no port recorded for $name"; return 1; }
  mkdir -p "$data" && chmod 700 "$data" 2>/dev/null
  # The app sets 0700/0600 on data/, cms.sqlite (+WAL sidecars) and media/ by
  # itself; nothing else in Termux may read a site's database.
  ( set -a; . "$envf"; set +a
    nohup node $NODE_FLAGS "$APP_FILE" >>"$DATA/logs/$name.log" 2>&1 &
    echo $! > "$(site_pid "$name")" )
  local i=0 code
  while (( i++ < 30 )); do
    sleep 0.5
    site_running "$name" || { err "$name died at once — last lines:"; tail -n 6 "$DATA/logs/$name.log" | sed 's/^/     /'; return 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/api/health" 2>/dev/null) || true
    [[ ${code:-000} =~ ^(200|503)$ ]] && return 0
  done
  err "$name did not answer on $port (see $DATA/logs/$name.log)"; return 1
}

stop_site() { # name
  local pid; pid=$(cat "$(site_pid "$1")" 2>/dev/null) || true
  [[ -n ${pid:-} ]] || { rm -f "$(site_pid "$1")"; return 0; }
  # SIGINT/SIGTERM is handled: the app closes the database and flushes WAL.
  kill "$pid" 2>/dev/null || true
  local i=0
  while (( i++ < 16 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$(site_pid "$1")"
}

restart_site() { stop_site "$1"; start_site "$1"; }

# One start carrying DB_PASSWORD_UNLOCK=1 removes the database lock and changes
# nothing else - that is the app's own escape hatch. It still listens, so give
# it the site's port, let it clear the lock, then kill it: it must never be left
# serving traffic with the check off.
unlock_once() { # name
  local name=$1 tmp pid
  tmp=$(mktemp -d)
  ( set -a; . "$ENV_DIR/$name.env"; set +a
    DB_PASSWORD_UNLOCK=1 HOST=127.0.0.1 PORT="$(site_port "$name")" \
      DATA_DIR="$(site_data "$name")" exec node $NODE_FLAGS "$APP_FILE" ) >"$tmp/log" 2>&1 &
  pid=$!
  sleep 2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  head -n 1 "$tmp/log" 2>/dev/null | sed 's/^/     /'
  rm -rf "$tmp"
}

all_sites() { grep -v '^#' "$REG_FILE" 2>/dev/null | cut -d'|' -f1; }

start_services() {
  local n started=0
  for n in $(all_sites); do start_site "$n" && (( started++ )); done
  start_nginx
  info "$started site(s) up."
}

stop_services() {
  local n
  nginx_running && nginx_cmd -s quit && ok "nginx stopped"
  for n in $(all_sites); do site_running "$n" && { stop_site "$n"; ok "site $n stopped"; }; done
}

reload_nginx() {
  write_base_configs
  if nginx_cmd -t >/dev/null 2>&1; then
    nginx_running && nginx_cmd -s reload || start_nginx
    return 0
  fi
  err "nginx config test failed:"; nginx_cmd -t; return 1
}

status_line() {
  local s n running=0 total=0
  nginx_running && s="${G}●${N} nginx" || s="${R}●${N} nginx"
  for n in $(all_sites); do (( total++ )); site_running "$n" && (( running++ )); done
  echo -e "  $s   ${G}${running}${N}/${total} sites up   ${D}port $HTTP_PORT${N}"
}

services_menu() {
  while true; do
    banner
    echo -e "${W}  SERVICES${N}"
    echo "  ─────────────────────────────────────────────"
    status_line
    echo -e "  ${D}app bundle: $(app_ready && app_version || echo 'NOT BUILT')${N}"
    echo
    echo "   1. Start all (every site + nginx)"
    echo "   2. Stop all"
    echo "   3. Restart all"
    echo "   4. Reload nginx only"
    echo "   5. Show the app log for a site"
    echo "   0. Back"
    read -rp "  Choose: " o
    case $o in
      1) start_services; pause ;;
      2) stop_services; pause ;;
      3) stop_services; sleep 1; start_services; pause ;;
      4) reload_nginx && ok "nginx reloaded"; pause ;;
      5) pick_site && { echo; tail -n 40 "$DATA/logs/$SEL.log" 2>/dev/null | sed 's/^/  /'; echo; pause; } ;;
      0) return ;;
    esac
  done
}

# ---------------------------------------------------------------------
#  ENVIRONMENT CHECK / INSTALL
# ---------------------------------------------------------------------
PKGS=(nginx git curl tar gzip openssl-tool)
# Left out on purpose: php, php-fpm, mariadb. This stack runs no PHP and there
# is no MySQL driver anywhere in the app — node:sqlite is its database. If you
# still keep old WordPress sites on the phone, uncomment:
# PKGS+=(php php-fpm mariadb)
# Node's package name differs by Termux snapshot, so it is tried separately.
NODE_PKGS=(nodejs-lts nodejs)

# What "the panel can run at all" means. Note git is only required when we are
# the ones building the bundle: APP_SOURCE=url ships one file and needs none.
env_missing() {
  local need_git=0
  [[ $APP_SOURCE == git ]] && ! app_ready && need_git=1
  have_cmd nginx && node_version_ok && have_cmd curl && have_cmd tar \
    && { (( need_git )) && have_cmd git || true; } \
    && node_sqlite_setup && return 1
  return 0
}

row() { # uses the caller's `bad`
  if [[ $2 == ok ]]; then printf "  ${G}✔${N} %-14s %s\n" "$1" "$3"
  else printf "  ${R}✘${N} %-14s ${R}missing${N}\n" "$1"; bad=1; fi
}

env_status() {
  local bad=0
  echo -e "  ${W}Device:${N} Android $(getprop ro.build.version.release 2>/dev/null || echo '?') / $(uname -m)   ${W}Free:${N} $(df -h "$HOME" 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4)"
  echo

  have_cmd nginx && row nginx ok "$(nginx -v 2>&1 | cut -d/ -f2)" || row nginx no
  node_installed && row node ok "$(node_label)  (need >= ${MIN_NODE_MAJOR}.${MIN_NODE_MINOR})" || row node no
  if node_installed; then
    if node_version_ok && node_sqlite_setup; then
      row "node:sqlite" ok "available ${NODE_FLAGS/--disable-warning=ExperimentalWarning/}"
    else
      row "node:sqlite" no
    fi
  else row "node:sqlite" no; fi
  have_cmd curl && row curl ok "" || row curl no
  have_cmd tar  && row tar ok "" || row tar no
  have_cmd git  && row git ok "$(git --version 2>/dev/null | awk '{print $3}')" || row git no
  have_cmd sqlite3 && row sqlite3 ok "hot backups enabled" || row sqlite3 no "optional"
  have_cmd termux-wake-lock && row "wake-lock" ok "" || row "wake-lock" no "optional"

  if app_ready; then
    row "app bundle" ok "$(app_version)  ·  $(du -h "$APP_FILE" | cut -f1)"
  else
    row "app bundle" no
  fi

  echo
  status_line
  echo -e "  ${D}Sites: $SITES_DIR   backups: $BACKUP_DIR${N}"
  return $bad
}

install_env() {
  info "Updating Termux packages..."
  pkg update -y || { err "pkg update failed"; return 1; }
  if ! node_version_ok; then
    local np
    for np in "${NODE_PKGS[@]}"; do
      info "Installing $np (need Node >= ${MIN_NODE_MAJOR}.${MIN_NODE_MINOR} for node:sqlite)..."
      pkg install -y "$np" >/dev/null 2>&1 && node_version_ok && { ok "node $(node_label)"; break; }
    done
  fi
  info "Installing: ${PKGS[*]}"
  pkg install -y "${PKGS[@]}" || { err "Install failed."; return 1; }
  hash -r
  node_sqlite_setup
  write_base_configs
  ok "Packages installed."
  ensure_app
  have_cmd termux-wake-lock && termux-wake-lock 2>/dev/null && info "Wake lock on (keeps Termux alive in background)."
}

check_environment() {
  banner
  echo -e "${W}  ENVIRONMENT CHECK${N}"
  echo "  ─────────────────────────────────────────────"
  if app_ready; then info "Bundle cached: $(app_version)"; else ensure_app || true; fi
  if env_status && ! env_missing; then
    echo; ok "Everything is installed."
    if ! nginx_running || any_site_down; then
      read -rp "  Some services are stopped. Start them now? [Y/n]: " a
      [[ $a =~ ^[Nn]$ ]] || start_services
    fi
  else
    echo; warn "Something required is missing (see the ✘ lines)."
    read -rp "  Install everything now? [Y/n]: " a
    if [[ ! $a =~ ^[Nn]$ ]]; then
      install_env && start_services
      echo; env_status
    fi
  fi
  pause
}

startup_check() {
  node_sqlite_setup
  if env_missing; then
    banner
    warn "Required software is not installed yet."
    echo; env_status; echo
    read -rp "  Install everything now? [Y/n]: " a
    [[ $a =~ ^[Nn]$ ]] || install_env
  fi
  node_sqlite_setup
  write_base_configs
  legacy_wordpress_check
  if ! env_missing; then
    app_ready || ensure_app || warn "App bundle missing — sites cannot start until option 5 or 7 succeeds."
    start_services
  fi
}

# v1 of this panel ran WordPress + php-fpm + mariadb. Those sites are NOT
# managed by v2 (different runtime, different database), and their folders
# would collide with a new site of the same name. Say so once, cleanly.
legacy_wordpress_check() {
  local n found=0
  [[ -f $REG_FILE ]] || return 0
  while IFS='|' read -r n d root db _rest; do
    [[ -z ${n:-} || $n == \#* ]] && continue
    # v2 records an absolute data dir in field 4; v1 recorded a DB name there.
    [[ ${db:-} != /* ]] && { found=1; break; }
  done < "$REG_FILE"
  (( found )) || { pidof php-fpm >/dev/null 2>&1 || pgrep -f 'php-fpm|mysqld|mariadbd' >/dev/null 2>&1 || return 0; }
  banner
  warn "This panel found leftovers from the WordPress edition."
  echo "   Your old WP sites and MariaDB are still on disk but v2 does not"
  echo "   manage them: the new stack has no PHP and no MySQL at all."
  echo
  echo "   Options: keep them as they are (they keep working if you restart"
  echo "   php-fpm/mariadb by hand), or use option 8 in this menu to remove"
  echo "   the old stack, or back each site up in phpMyAdmin/mysqldump first."
  echo
  read -rp "  Press Enter to continue into the panel... " _ || true
}

# ---------------------------------------------------------------------
#  Provisioning helpers — this is what replaced wp-config.php + the
#  "open the URL and click through the 5-minute install" step.
#  The app exposes both halves a panel needs, already:
#    GET  /api/health  answers BEFORE install (it is routed ahead of the
#                      install gate) => {ok, runtime, installed, checks}
#    POST /install     form-encoded, sameOrigin() only (a non-browser
#                      client sends no Origin header, so it passes) and the
#                      handler is refused once a user row exists.
# ---------------------------------------------------------------------
health_json() { # port
  curl -sS --max-time 5 "http://127.0.0.1:$1/api/health" 2>/dev/null
}

wait_health() { # port [tries]
  local port=$1 tries=${2:-40} i=0 body
  while (( i++ < tries )); do
    body=$(health_json "$port")
    [[ -n $body ]] && { printf '%s' "$body"; return 0; }
    sleep 0.5
  done
  return 1
}

is_installed() { [[ $(health_json "$1") == *'"installed":true'* ]]; }

site_env_write() { # name data port dbpw
  local f="$ENV_DIR/$1.env"
  umask 077
  cat > "$f" <<EOF
# AHMED WEB PANEL — environment for site '$1'. chmod 600.
# The app reads ONLY these five variables; DATA_DIR is the whole site
# (database + media + the DB_PASSWORD hash sidecar), so this file plus that
# folder is everything a restore needs.
HOST=127.0.0.1
PORT=$3
DATA_DIR=$2
TRUST_PROXY=1
DB_PASSWORD=$4
EOF
  chmod 600 "$f" 2>/dev/null || true
}

provision_site() { # name port admin_slug admin_user admin_pass email domain title
  local name=$1 port=$2 slug=$3 user=$4 pass=$5 email=$6 domain=$7 title=$8
  local body out code
  body=$(wait_health "$port") || { err "the app never answered on port $port"; return 1; }
  if [[ $body == *'"installed":true'* ]]; then info "Already installed — skipping the installer."; return 0; fi
  info "Running the installer headlessly..."
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' --max-time 60 \
    --data-urlencode "username=$user" \
    --data-urlencode "email=$email" \
    --data-urlencode "password=$pass" \
    --data-urlencode "password2=$pass" \
    --data-urlencode "title=$title" \
    --data-urlencode "domain=$domain" \
    --data-urlencode "slug=$slug" \
    "http://127.0.0.1:$port/install")
  # Trust /api/health, never the page: the wizard re-renders with field errors
  # on 400 and the success page is not a stable thing to grep.
  if [[ $(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$port/install" 2>/dev/null) != 404 ]]; then
    err "install did not take (HTTP ${code:-?}). App said:"
    grep -o -E '<div>[^<]{0,140}' "$out" | sed -e 's/<div>/     - /' | head -6
    rm -f "$out"; return 1
  fi
  rm -f "$out"
  ok "Installed, installer now locked (HTTP 404 on /install)."
}

# Proof that the credentials the panel printed really work: the login form is
# protected by a double-submit CSRF token (cms_csrf cookie + _csrf field whose
# value is HMAC(site secret, 'csrf:'+cookie)), so the only portable way in is
# the browser's own dance. Same sequence tests/helpers.mjs uses.
verify_login() { # port slug user pass -> 0 when the panel really opened
  local port=$1 slug=$2 user=$3 pass=$4 jar tok code
  jar=$(mktemp -d)
  tok=$(curl -sS -c "$jar/c.txt" "http://127.0.0.1:$port/$slug/login" 2>/dev/null \
        | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"//')
  [[ -n $tok ]] || { rm -rf "$jar"; return 1; }
  curl -sS -b "$jar/c.txt" -c "$jar/c.txt" -o /dev/null --max-time 20 \
       -e "http://127.0.0.1:$port/$slug/login" \
       --data-urlencode "_csrf=$tok" \
       --data-urlencode "login=$user" \
       --data-urlencode "password=$pass" \
       "http://127.0.0.1:$port/$slug/login"
  # A redirect status proves nothing: go() answers 303 on success AND on a
  # wrong password (with a flash query). The honest signal is the session
  # cookie, which startSession() sets only once the password verified...
  if ! grep -q cms_session "$jar/c.txt"; then rm -rf "$jar"; return 1; fi
  # ...and the panel must render for it. Unauthenticated, /$slug/ bounces to
  # /login, so a 200 on the dashboard is the confirmation.
  code=$(curl -sS -b "$jar/c.txt" -o "$jar/d.html" -w '%{http_code}' --max-time 20 \
          "http://127.0.0.1:$port/$slug/")
  rm -rf "$jar"
  [[ $code == 200 ]]
}

# ---------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------
pick_site() {
  SEL=""
  [[ -s $REG_FILE ]] || { warn "No websites yet."; return 1; }
  local i=1 names=() n d root dd p sl
  echo
  while IFS='|' read -r n d root dd p sl; do
    [[ $n == \#* || -z $n ]] && continue
    printf "   ${Y}%2d)${N} %-16s %s\n" "$i" "$n" "${d:-no domain}"
    names+=("$n"); ((i++))
  done < "$REG_FILE"
  (( ${#names[@]} )) || { warn "No websites yet."; return 1; }
  echo "    0) Cancel"
  echo
  read -rp "  Select website number: " num
  [[ $num =~ ^[0-9]+$ ]] || { err "Invalid choice"; return 1; }
  (( num == 0 )) && return 1
  (( num >= 1 && num <= ${#names[@]} )) || { err "Invalid choice"; return 1; }
  SEL="${names[$((num-1))]}"
}

port_free() { ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/" 2>/dev/null; }

next_port() {
  local max=$((SITE_PORT_BASE - 1)) p
  while IFS='|' read -r _ _ _ _ p _; do
    [[ $p =~ ^[0-9]+$ ]] && (( p > max )) && max=$p
  done < "$REG_FILE"
  p=$((max + 1))
  while ! port_free "$p" && (( p < 65000 )); do ((p++)); done
  echo "$p"
}

# ---------------------------------------------------------------------
#  1. LIST WEBSITES
# ---------------------------------------------------------------------
list_sites() {
  banner
  echo -e "${W}  ALL WEBSITES${N}"
  echo "  ─────────────────────────────────────────────"
  status_line; echo
  [[ -s $REG_FILE ]] || { warn "No websites added yet. Use option 2."; pause; return; }
  local i=1 n d root data port slug state inst up ver
  while IFS='|' read -r n d root data port slug; do
    [[ $n == \#* || -z $n ]] && continue
    up="${R}process down${N}"
    site_running "$n" && up="${G}running${N}"
    inst="${Y}installer pending${N}"
    if site_running "$n"; then
      is_installed "$port" && inst="${G}installed${N}"
    fi
    echo -e "  ${Y}$i)${N} ${W}$n${N}  [$up | $inst]"
    echo -e "     open      : ${C}http://localhost:$port${N}   (or http://$d:$HTTP_PORT through nginx)"
    echo -e "     admin     : ${C}http://localhost:$port/$slug${N}"
    echo -e "     domains   : $(domains_of "$n")"
    echo -e "     folder    : $root"
    echo -e "     database  : $data/cms.sqlite   (no MySQL — one SQLite file per site)"
    echo
    ((i++))
  done < "$REG_FILE"
  echo -e "  Total: $((i-1)) website(s)   ${D}app: $(app_ready && app_version || echo 'NOT BUILT')${N}"
  pause
}

# ---------------------------------------------------------------------
#  2. ADD NEW WEBSITE
# ---------------------------------------------------------------------
add_site() {
  banner
  echo -e "${W}  ADD NEW WEBSITE${N}"
  echo "  ─────────────────────────────────────────────"
  env_missing && { err "Environment incomplete. Run option 5 first."; pause; return; }
  node_sqlite_setup
  ensure_app || { pause; return; }
  have_cmd nginx || { err "nginx is not installed. Run option 5."; pause; return; }

  read -rp "  Site name (lowercase letters/numbers/_, e.g. myblog): " name
  valid_name "$name" || { err "Invalid name. 2-20 chars, start with a letter, [a-z0-9_]."; pause; return; }
  site_exists "$name" && { err "Site '$name' already exists."; pause; return; }

  read -rp "  Primary domain (e.g. example.com, or none for testing): " domain
  domain=${domain,,}; domain=${domain#www.}
  if [[ -n $domain && $domain != none ]]; then
    valid_domain "$domain" || { err "Invalid domain. Or type 'none' to skip."; pause; return; }
    domain_in_use "$domain" && { err "$domain is already used by another site."; pause; return; }
  else
    domain="$name.local"
    info "No domain: the site will answer on http://localhost:<port> only."
  fi

  local root="$SITES_DIR/$name" data="$SITES_DIR/$name/data" port slug
  local admin_user admin_pass email title dbpass
  [[ -e $root ]] && { err "$root already exists (an old WordPress site with this name?). Pick another name or delete that folder."; pause; return; }
  port=$(next_port)
  slug="admin-$(rand 8 | tr 'A-Z' 'a-z')"      # the panel URL is random by design; it is not linked from the site
  dbpass=$(rand 28)
  read -rp "  Admin username [admin]: " admin_user; admin_user=${admin_user:-admin}
  [[ $admin_user =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || { err "Username: 3-32 letters, digits, dot, dash or underscore."; pause; return; }
  read -rp "  Admin email [admin@$domain]: " email; email=${email:-admin@$domain}
  [[ $email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { err "Not a valid email."; pause; return; }
  read -rp "  Site title [$name]: " title; title=${title:-$name}
  admin_pass=$(rand 16)

  echo
  info "Creating folders..."
  mkdir -p "$data" "$root" || { err "could not create $root"; return; }
  chmod 700 "$data" 2>/dev/null
  site_env_write "$name" "$data" "$port" "$dbpass"

  info "Starting the app on 127.0.0.1:$port..."
  if ! start_site "$name"; then
    rm -rf "${root:?}"; rm -f "$ENV_DIR/$name.env" "$DATA/logs/$name.log"
    err "Rolled back. Nothing was saved."; pause; return
  fi

  if ! provision_site "$name" "$port" "$slug" "$admin_user" "$admin_pass" "$email" "$domain" "$title"; then
    stop_site "$name"
    rm -rf "${root:?}"; rm -f "$ENV_DIR/$name.env" "$DATA/logs/$name.log"
    err "Rolled back so you can try again."; pause; return
  fi

  printf '%s\nwww.%s\n' "$domain" "$domain" > "$DATA/$name.domains"
  write_site_conf "$name" "$(domains_of "$name")" "$root" "$port"
  if ! reload_nginx; then
    err "nginx rejected the config. Cleaning up so you can try again..."
    rm -f "$NGX_SITES/$name.conf" "$DATA/$name.domains"
    write_site_conf "$name" "$(domains_of "$name")" "$root" "$port"; reload_nginx >/dev/null 2>&1
    stop_site "$name"
    rm -rf "${root:?}"; rm -f "$ENV_DIR/$name.env"
    pause; return
  fi

  echo "$name|$domain|$root|$data|$port|$slug" >> "$REG_FILE"
  umask 077
  cat > "$DATA/$name.credentials" <<EOF
site        : $name
created     : $(date -u +%FT%TZ)
app         : $(app_version)
data dir    : $data          <- this folder IS the site (db + media + backups)
env file    : $ENV_DIR/$name.env
DB_PASSWORD : $dbpass
lost the DB password? one start with DB_PASSWORD_UNLOCK=1 clears the check
admin url   : http://localhost:$port/$slug   (then /$slug through nginx, port $HTTP_PORT)
admin user  : $admin_user
admin pass  : $admin_pass     (change it now: Profile, in the panel)
EOF
  chmod 600 "$DATA/$name.credentials" 2>/dev/null
  ok "Credentials saved to $DATA/$name.credentials (0600)."

  if verify_login "$port" "$slug" "$admin_user" "$admin_pass"; then
    ok "Login verified against the running site."
  else
    warn "Could not log in automatically — check $DATA/logs/$name.log"
  fi

  echo
  ok "Website '$name' is live."
  echo -e "   Open in the phone browser : ${C}http://localhost:$port/$slug${N}"
  echo -e "   Public through nginx      : ${C}http://$domain:$HTTP_PORT/${N}"
  echo -e "   Folder   : $root"
  echo -e "   Database : $data/cms.sqlite"
  echo
  echo -e "   ${Y}Note:${N} the app ships ${W}no themes${N} — a fresh site is plain, unstyled"
  echo "   HTML on purpose. Upload a theme zip in Appearance -> Themes, or"
  echo "   start one from Appearance -> Themes -> New theme from a template."
  pause
}

# ---------------------------------------------------------------------
#  3. ADD CUSTOM DOMAIN  (stack-agnostic: it only touches nginx)
# ---------------------------------------------------------------------
server_ip() { curl -fsS4 --max-time 6 https://ifconfig.me 2>/dev/null; }
domain_ip() {
  curl -fsS --max-time 8 "https://dns.google/resolve?name=$1&type=A" 2>/dev/null \
    | grep -o '"data":"[0-9.]*"' | head -n1 | cut -d'"' -f4
}

dns_check() {
  local sip dip; sip=$(server_ip); dip=$(domain_ip "$1")
  echo
  echo -e "  This device's public IP : ${W}${sip:-unknown}${N}"
  echo -e "  $1 points to          : ${W}${dip:-not resolving yet}${N}"
  [[ -n $sip && $sip == "$dip" ]] && { ok "DNS is pointing to this device."; return 0; }
  warn "DNS does not point here yet."
  return 1
}

registrar_guide() {
  local sip; sip=$(server_ip); sip=${sip:-<your-IP>}
  echo
  echo -e "${W}  ┌─ AT YOUR DOMAIN REGISTRAR (Namecheap, GoDaddy...) ─┐${N}"
  echo
  echo -e "  Your IP is:  ${G}${sip}${N}"
  echo "  Add two DNS records; do not change nameservers."
  echo
  echo -e "        Type: ${Y}A Record${N}   Host: ${Y}@${N}     Value: ${Y}${sip}${N}   TTL: Automatic"
  echo -e "        Type: ${Y}A Record${N}   Host: ${Y}www${N}   Value: ${Y}${sip}${N}   TTL: Automatic"
  echo
  echo -e "  ${D}Phone caveats: the web port is $HTTP_PORT, and mobile networks usually"
  echo -e "  hide your device behind CGNAT, so a visitor may never reach you. Two"
  echo -e "  fixes: run this on a VPS (port 80/443, TLS), or put a Cloudflare"
  echo -e "  tunnel in front (pkg install cloudflared) — that also gives you HTTPS"
  echo -e "  without a certificate on the phone. The app itself can also be"
  echo -e "  deployed to Cloudflare Workers and skip this machine entirely.${N}"
  echo
  echo -e "${W}  └────────────────────────────────────────────────────┘${N}"
}

add_domain_to() {
  banner
  echo -e "${W}  ADD CUSTOM DOMAIN TO: $1${N}"
  echo "  ─────────────────────────────────────────────"
  local name=$1 root port
  root=$(site_root "$name"); port=$(site_port "$name")
  echo
  echo "  Current domains: $(domains_of "$name")"
  read -rp "  Enter the new domain (e.g. mybrand.com): " nd
  nd=${nd,,}; nd=${nd#www.}
  valid_domain "$nd" || { err "Invalid domain."; pause; return; }
  local already=0
  if domain_in_use "$nd"; then
    if grep -qxF -- "$nd" "$DATA/$name.domains" 2>/dev/null; then
      already=1
    else
      err "$nd is already attached to a different website."; pause; return
    fi
  fi
  if (( already )); then
    echo; info "$nd is already attached to '$name'. Showing the DNS steps again."
  else
    cp "$DATA/$name.domains" "$DATA/$name.domains.bak"
    printf '%s\nwww.%s\n' "$nd" "$nd" >> "$DATA/$name.domains"
    write_site_conf "$name" "$(domains_of "$name")" "$root" "$port"
    if ! reload_nginx; then
      mv -f "$DATA/$name.domains.bak" "$DATA/$name.domains"
      write_site_conf "$name" "$(domains_of "$name")" "$root" "$port"
      reload_nginx >/dev/null 2>&1
      err "Could not attach $nd. Nothing was saved, so you can try again."; pause; return
    fi
    rm -f "$DATA/$name.domains.bak"
    echo; ok "Saved! $nd (and www.$nd) now points at website '$name'."
  fi
  echo -e "  Test link: ${C}http://localhost:$port${N}"
  registrar_guide "$nd"
  while true; do
    echo
    echo -e "  ${W}What next?${N}"
    echo "   1) Check if DNS is working now"
    echo "   2) Show the registrar guide again"
    echo "   0) Done"
    read -rp "  Choose: " o
    case $o in
      1) dns_check "$nd" ;;
      2) registrar_guide "$nd" ;;
      0) break ;;
      *) err "Invalid option" ;;
    esac
  done
  pause
}

# ---------------------------------------------------------------------
#  3b. MANAGE CUSTOM DOMAINS
# ---------------------------------------------------------------------
domain_roots() { grep -v '^www\.' "$DATA/$1.domains" 2>/dev/null; }

list_domains() {
  local prim d i=1 tag; prim=$(get_field "$1" 2)
  while IFS= read -r d; do
    [[ -z $d ]] && continue
    tag=""; [[ $d == "$prim" ]] && tag="  ${G}(primary)${N}"
    printf "   ${Y}%2d)${N} %s%b\n" "$i" "$d" "$tag"; ((i++))
  done < <(domain_roots "$1")
}

pick_domain() {
  DSEL=""
  local roots=() d
  while IFS= read -r d; do [[ -n $d ]] && roots+=("$d"); done < <(domain_roots "$1")
  (( ${#roots[@]} )) || { warn "This website has no domains."; return 1; }
  echo; list_domains "$1"; echo "    0) Cancel"; echo
  read -rp "  Select domain number: " num
  [[ $num =~ ^[0-9]+$ ]] || { err "Invalid choice"; return 1; }
  (( num == 0 )) && return 1
  (( num >= 1 && num <= ${#roots[@]} )) || { err "Invalid choice"; return 1; }
  DSEL="${roots[$((num-1))]}"
}

domain_snapshot() { cp -f "$DATA/$1.domains" "$DATA/$1.domains.bak"; }

domain_commit() {
  local name=$1 root port
  root=$(site_root "$name"); port=$(site_port "$name")
  write_site_conf "$name" "$(domains_of "$name")" "$root" "$port"
  if reload_nginx; then rm -f "$DATA/$name.domains.bak"; return 0; fi
  mv -f "$DATA/$name.domains.bak" "$DATA/$name.domains"
  write_site_conf "$name" "$(domains_of "$name")" "$root" "$port"
  reload_nginx >/dev/null 2>&1
  return 1
}

domain_check_all() {
  local d
  while IFS= read -r d; do
    [[ -z $d ]] && continue
    echo; echo -e "  ${W}$d${N}"; dns_check "$d"
  done < <(domain_roots "$1")
}

domain_edit() {
  local name=$1 old new tmp line is_primary=0
  pick_domain "$name" || return
  old=$DSEL
  [[ $(get_field "$name" 2) == "$old" ]] && is_primary=1
  read -rp "  New name for $old (e.g. mybrand.com): " new
  new=${new,,}; new=${new#www.}
  valid_domain "$new" || { err "Invalid domain."; return; }
  [[ $new == "$old" ]] && { info "Same name, nothing to change."; return; }
  domain_in_use "$new" && { err "$new is already attached to a website."; return; }
  domain_snapshot "$name"
  tmp=$(mktemp)
  while IFS= read -r line; do
    if   [[ $line == "$old"     ]]; then echo "$new"
    elif [[ $line == "www.$old" ]]; then echo "www.$new"
    else echo "$line"; fi
  done < "$DATA/$name.domains" > "$tmp"
  cat "$tmp" > "$DATA/$name.domains"; rm -f "$tmp"
  if ! domain_commit "$name"; then
    err "Could not apply the change. Nothing was changed."; return
  fi
  (( is_primary )) && sed -i -E "s#^($name\|)[^|]*#\1$new#" "$REG_FILE"
  ok "Changed $old -> $new (and www.$new)."
  (( is_primary )) && echo -e "  ${D}WordPress no longer exists here, so nothing to update in a settings screen:"
  (( is_primary )) && echo -e "  ${D}the app derives the site name from the Host header, and Settings -> Site title overrides it globally.${N}"
}

domain_remove() {
  local name=$1 d
  pick_domain "$name" || return
  d=$DSEL
  if [[ $(get_field "$name" 2) == "$d" ]]; then
    err "$d is the PRIMARY domain of '$name', so it can't be removed."
    echo "   Attach another domain first, or delete the website."
    return
  fi
  read -rp "  Remove $d and www.$d from '$name'? [y/N]: " c
  [[ $c =~ ^[Yy]$ ]] || { info "Cancelled."; return; }
  domain_snapshot "$name"
  grep -vxF -e "$d" -e "www.$d" "$DATA/$name.domains.bak" > "$DATA/$name.domains"
  if ! domain_commit "$name"; then
    err "Could not apply the change. Nothing was removed."; return
  fi
  ok "Removed $d from '$name'."
}

manage_domains() {
  banner
  echo -e "${W}  CUSTOM DOMAINS${N}"
  echo "  ─────────────────────────────────────────────"
  pick_site || { pause; return; }
  local name=$SEL
  while true; do
    banner
    echo -e "${W}  CUSTOM DOMAINS - $name${N}"
    echo "  ─────────────────────────────────────────────"
    list_domains "$name"
    echo
    echo -e "   ${Y}1)${N} Add a domain"
    echo -e "   ${Y}2)${N} Check DNS"
    echo -e "   ${Y}3)${N} Edit a domain (rename)"
    echo -e "   ${Y}4)${N} Remove a domain"
    echo -e "   ${Y}5)${N} Registrar guide"
    echo -e "   ${Y}0)${N} Back"
    read -rp "  Choose: " o
    case $o in
      1) add_domain_to "$name" ;;
      2) domain_check_all "$name"; pause ;;
      3) domain_edit "$name"; pause ;;
      4) domain_remove "$name"; pause ;;
      5) pick_domain "$name" && { registrar_guide "$DSEL"; pause; } ;;
      0) return ;;
      *) err "Invalid option"; sleep 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------
#  BACKUP / RESTORE
#  One folder is the site, so this is a copy — not mysqldump + docroot.
#  A SQLite file in WAL mode is NOT safe to copy on its own: the -wal sidecar
#  holds committed rows. So either let sqlite3 write a consistent snapshot
#  (VACUUM INTO, hot, no downtime), or stop the process first.
# ---------------------------------------------------------------------
backup_site() { # name
  local name=$1 root data ts out stage was=0
  root=$(site_root "$name"); data=$(site_data "$name")
  ts=$(date +%Y%m%d-%H%M%S); out="$BACKUP_DIR/$name-$ts.tar.gz"
  mkdir -p "$BACKUP_DIR"
  site_running "$name" && was=1

  # Every archive carries the panel-side bits too (registry line, env file with
  # DB_PASSWORD, domains): data/ alone cannot be restored without them.
  stage=$(mktemp -d)
  printf '%s|%s|%s|%s|%s|%s\n' "$name" "$(get_field "$name" 2)" "$root" "$data" "$(site_port "$name")" "$(site_slug "$name")" > "$stage/registry-line.txt"
  printf 'app: %s\nbackup: %s\nsite: %s\n' "$(app_version)" "$ts" "$name" > "$stage/meta.txt"
  local members=(registry-line.txt meta.txt)
  if [[ -f $ENV_DIR/$name.env ]]; then cp "$ENV_DIR/$name.env" "$stage/site.env" && members+=(site.env); fi
  if [[ -f $DATA/$name.domains ]]; then cp "$DATA/$name.domains" "$stage/domains" && members+=(domains); fi

  if have_cmd sqlite3 && [[ -f $data/cms.sqlite ]]; then
    info "Snapshotting the database while the site keeps running..."
    mkdir -p "$stage/data"
    if sqlite3 "$data/cms.sqlite" "VACUUM INTO '$stage/data/cms.sqlite'" 2>/dev/null; then
      # live data/ MINUS its database files, plus the one consistent snapshot
      members+=(data/cms.sqlite)
      tar czf "$out" -C "$root" \
              --exclude='cms.sqlite' --exclude='cms.sqlite-wal' --exclude='cms.sqlite-shm' data \
              -C "$stage" "${members[@]}" 2>/dev/null
      rm -rf "$stage"
      [[ -s $out ]] && { ok "Backup: $out ($(du -h "$out" | cut -f1)) — site stayed up."; return 0; }
      err "backup failed"; return 1
    fi
    warn "snapshot failed — falling back to a cold copy."
  fi

  info "Backing up (site is stopped for a few seconds)..."
  stop_site "$name"
  tar czf "$out" -C "$root" data -C "$stage" "${members[@]}" 2>/dev/null
  rm -rf "$stage"
  (( was )) && start_site "$name"
  [[ -s $out ]] && { ok "Backup: $out ($(du -h "$out" | cut -f1))"; return 0; }
  err "backup failed"; return 1
}

restore_site() {
  banner
  echo -e "${W}  RESTORE A WEBSITE FROM A BACKUP${N}"
  echo "  ─────────────────────────────────────────────"
  local files=() f i=1 name root data stage
  while IFS= read -r f; do files+=("$f"); done < <(find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | sort -r)
  (( ${#files[@]} )) || { warn "No backups in $BACKUP_DIR."; pause; return; }
  for f in "${files[@]}"; do printf "   ${Y}%2d)${N} %s  (%s)\n" "$i" "$(basename "$f")" "$(du -h "$f" | cut -f1)"; ((i++)); done
  echo "    0) Cancel"; echo
  read -rp "  Restore which backup? " num
  [[ $num =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#files[@]} )) || { info "Cancelled."; return; }
  f="${files[$((num-1))]}"
  stage=$(mktemp -d)
  tar xzf "$f" -C "$stage" 2>/dev/null || { err "could not read that archive"; rm -rf "$stage"; pause; return; }
  [[ -d $stage/data ]] || { err "archive holds no data/ folder - not a v2 backup."; rm -rf "$stage"; pause; return; }
  name=$(basename "$f"); name=${name%%-[0-9]*}
  [[ -f $stage/registry-line.txt ]] && name=$(cut -d'|' -f1 "$stage/registry-line.txt" | head -1)
  echo
  echo -e "  Archive : $(basename "$f")"
  echo -e "  Site    : ${W}$name${N}"
  read -rp "  Overwrite the current files of '$name'? Its data folder is replaced. [y/N]: " c
  [[ $c =~ ^[Yy]$ ]] || { info "Cancelled."; rm -rf "$stage"; return; }
  root="$SITES_DIR/$name"; data="$root/data"
  stop_site "$name"
  mkdir -p "$root"
  rm -rf "${data:?}"
  cp -a "$stage/data" "$data"
  chmod 700 "$data" 2>/dev/null
  chmod -R u+rwX "$data" 2>/dev/null
  [[ -f $stage/site.env ]] && { cp "$stage/site.env" "$ENV_DIR/$name.env"; chmod 600 "$ENV_DIR/$name.env"; }
  [[ -f $stage/domains   ]] && { cp "$stage/domains" "$DATA/$name.domains"; }
  if ! grep -q "^$name|" "$REG_FILE" 2>/dev/null; then
    if [[ -f $stage/registry-line.txt ]]; then
      cat "$stage/registry-line.txt" >> "$REG_FILE"
    else
      echo "$name|restored.local|$root|$data|$(next_port)|admin-restored" >> "$REG_FILE"
    fi
  fi
  if [[ -f $stage/domains ]]; then
    write_site_conf "$name" "$(domains_of "$name")" "$root" "$(site_port "$name")" && reload_nginx
  fi
  rm -rf "$stage"
  if start_site "$name"; then
    ok "Restored. Site '$name' is running on port $(site_port "$name")."
    info "The admin URL lives inside the site, not the archive: it was set at install time."
  else
    err "Restored, but the site will not start. If the DB password was lost, clear the lock:"
    err "  option 9 -> change the DB_PASSWORD lock -> leave the new password empty."
  fi
  pause
}

# ---------------------------------------------------------------------
#  4. DELETE WEBSITE
# ---------------------------------------------------------------------
delete_site() {
  banner
  echo -e "${R}  DELETE WEBSITE${N}"
  echo "  ─────────────────────────────────────────────"
  pick_site || { pause; return; }
  local name=$SEL root data
  root=$(site_root "$name"); data=$(site_data "$name")
  echo
  warn "This removes: $root (database + all uploads), its nginx config, domains and credentials."
  echo -e "${D}   The app's own 'Tools -> Danger zone -> Reset the panel' does the same thing"
  echo -e "   from inside the site and asks for the admin password + the word RESET.${N}"
  read -rp "  Type the site name ($name) to confirm: " c
  [[ $c == "$name" ]] || { info "Cancelled."; pause; return; }
  read -rp "  Back up files + database to $BACKUP_DIR first? [Y/n]: " b
  [[ $b =~ ^[Nn]$ ]] || backup_site "$name"
  stop_site "$name"
  rm -f "$NGX_SITES/$name.conf" "$DATA/$name.domains" "$DATA/$name.credentials" \
        "$ENV_DIR/$name.env" "$DATA/logs/$name.log"
  reload_nginx
  rm -rf "${root:?}"
  sed -i "/^$name|/d" "$REG_FILE"
  ok "Website '$name' deleted."
  pause
}

# ---------------------------------------------------------------------
#  7. UPDATE THE APP BUNDLE  (one file for every site)
# ---------------------------------------------------------------------
update_app() {
  banner
  echo -e "${W}  UPDATE THE APP${N}"
  echo -e "  current: ${D}$(app_ready && app_version || echo 'not built')${N}"
  echo "  ─────────────────────────────────────────────"
  echo "  Rebuilds the single server.mjs and swaps it in. Migrations run"
  echo "  themselves on each site's 60s tick (or Appearance->Updates -> Run"
  echo "  updates now). They are FORWARD-ONLY, so take a backup first."
  echo
  read -rp "  Back up every site before updating? [Y/n]: " b
  if [[ ! $b =~ ^[Nn]$ ]]; then local n; for n in $(all_sites); do backup_site "$n"; done; fi
  [[ -f $APP_FILE ]] && cp -f "$APP_FILE" "$APP_FILE.previous" && info "Kept $APP_FILE.previous for rollback."
  if ensure_app force; then
    ok "New bundle in place: $(app_version)"
    local n; for n in $(all_sites); do restart_site "$n" && ok "restarted $n"; done
  else
    if [[ -f $APP_FILE.previous ]]; then
      mv -f "$APP_FILE.previous" "$APP_FILE"
      warn "Update failed — previous bundle restored."
    fi
  fi
  pause
}

rollback_app() {
  banner
  echo -e "${W}  ROLL THE APP BACK TO THE PREVIOUS BUNDLE${N}"
  [[ -f $APP_FILE.previous ]] || { warn "No previous bundle (run option 7 once first)."; pause; return; }
  read -rp "  Swap in server.mjs.previous and restart all sites? [y/N]: " c
  [[ $c =~ ^[Yy]$ ]] || { info "Cancelled."; return; }
  local t; t=$(mktemp)
  cp -f "$APP_FILE" "$t"; cp -f "$APP_FILE.previous" "$APP_FILE"; mv -f "$t" "$APP_FILE.previous"
  local n; for n in $(all_sites); do restart_site "$n"; done
  ok "Rolled back."
  pause
}

# ---------------------------------------------------------------------
#  9. SITE ACTIONS
# ---------------------------------------------------------------------
site_actions() {
  pick_site || { pause; return; }
  local name=$SEL port slug root
  port=$(site_port "$name"); slug=$(site_slug "$name"); root=$(site_root "$name")
  while true; do
    banner
    echo -e "${W}  SITE: $name${N}  ${D}$port / $slug${N}"
    echo "  ─────────────────────────────────────────────"
    if site_running "$name"; then echo -e "  ${G}● running${N}"; else echo -e "  ${R}● stopped${N}"; fi
    is_installed "$port" && echo -e "  ${G}installed${N}" || echo -e "  ${Y}installer pending${N}"
    echo -e "  admin: ${C}http://localhost:$port/$slug${N}   creds: $DATA/$name.credentials"
    echo -e "  size : $(du -sh "$root" 2>/dev/null | cut -f1)"
    echo
    echo -e "   ${Y}1)${N} Start      ${Y}2)${N} Stop       ${Y}3)${N} Restart"
    echo -e "   ${Y}4)${N} Last 40 log lines"
    echo -e "   ${Y}5)${N} Test login (panel -> dashboard, over HTTP)"
    echo -e "   ${Y}6)${N} Show credentials"
    echo -e "   ${Y}7)${N} Backup this site"
    echo -e "   ${Y}8)${N} Re-run the installer (only if 'installer pending')"
    echo -e "   ${Y}9)${N} Change the DB_PASSWORD lock (rotate / clear)"
    echo -e "   ${Y}0)${N} Back"
    read -rp "  Choose: " o
    case $o in
      1) start_site "$name" ;;
      2) stop_site "$name"; ok "stopped" ;;
      3) restart_site "$name" ;;
      4) echo; tail -n 40 "$DATA/logs/$name.log" 2>/dev/null | sed 's/^/  /'; echo ;;
      5) if site_running "$name"; then
           read -rp "  username: " u; read -rsp "  password: " p; echo
           if verify_login "$port" "$slug" "$u" "$p"; then ok "Login works."; else err "Login refused."; fi
         else err "start the site first"; fi ;;
      6) sed 's/^/  /' "$DATA/$name.credentials" 2>/dev/null || warn "no credentials file" ;;
      7) backup_site "$name" ;;
      8) read -rp "  admin username [admin]: " u; u=${u:-admin}
         read -rp "  admin email: " e
         read -rsp "  admin password (8+ chars): " pw; echo
         provision_site "$name" "$port" "$slug" "$u" "$pw" "$e" "$(get_field "$name" 2)" "$name" ;;
      9) echo "  The database is a file, so there is no account to authenticate:"
         echo "  DB_PASSWORD is an access check - a start that cannot present the"
         echo "  right one exits before it listens. Rotating means CLEAR first, then"
         echo "  re-lock: the app remembers the one it was locked to."
         read -rp "  New DB password, min 8 chars (empty = only clear the lock): " np
         stop_site "$name"
         info "Clearing the current lock..."
         unlock_once "$name"
         sed -i '/^DB_PASSWORD=/d' "$ENV_DIR/$name.env"
         if [[ -n $np ]]; then
           if (( ${#np} < 8 )); then err "Too short - the app refuses anything under 8. Lock left clear."; else
             echo "DB_PASSWORD=$np" >> "$ENV_DIR/$name.env"
             sed -i "s/DB_PASSWORD : .*/DB_PASSWORD : $np/" "$DATA/$name.credentials" 2>/dev/null
             start_site "$name" && ok "Re-locked with the new password."
           fi
         else
           warn "Lock cleared: this site now starts without any DB_PASSWORD."
           start_site "$name"
         fi ;;
      0) return ;;
      *) err "Invalid option" ;;
    esac
    sleep 0.4
  done
}

# ---------------------------------------------------------------------
#  8. FULL WIPE
# ---------------------------------------------------------------------
wipe_all() {
  banner
  echo -e "${R}  FULL WIPE - UNINSTALL EVERYTHING${N}"
  echo "  ─────────────────────────────────────────────"
  echo "  This will PERMANENTLY remove:"
  echo "    - every website: files, SQLite database, uploads, backups"
  echo "    - nginx + its config/logs, the built app bundle and the build tree"
  echo "    - this panel's data (~/.ahmed-panel)"
  echo "  It will NOT remove: curl, tar, git, nodejs or other normal Termux tools."
  echo
  read -rp "  Type  WIPE EVERYTHING  to continue: " c
  [[ $c == "WIPE EVERYTHING" ]] || { info "Cancelled. Nothing was changed."; pause; return; }

  local n d root db ts del_backups=0 del_self=0
  if [[ -s $REG_FILE ]]; then
    read -rp "  Save a backup of all websites first? [y/N]: " b
    if [[ $b =~ ^[Yy]$ ]]; then
      ts=$(date +%Y%m%d-%H%M%S)
      for n in $(all_sites); do
        stop_site "$n" 2>/dev/null
        root=$(site_root "$n")
        [[ -d $root ]] && tar czf "$BACKUP_DIR/$n-$ts-files.tar.gz" -C "$(dirname "$root")" "$(basename "$root")" 2>/dev/null
      done
      ok "Backups saved in $BACKUP_DIR (they survive the wipe)."
    fi
  fi
  if [[ -d $BACKUP_DIR ]] && [[ -n $(ls -A "$BACKUP_DIR" 2>/dev/null) ]]; then
    read -rp "  Also delete the backups folder ($BACKUP_DIR)? [y/N]: " x
    [[ $x =~ ^[Yy]$ ]] && del_backups=1
  else
    del_backups=1
  fi
  read -rp "  Also delete this script file when finished? [y/N]: " y
  [[ $y =~ ^[Yy]$ ]] && del_self=1

  step() { echo -e "${C}[ .. ]${N} $*"; }
  echo
  step "Stopping services..."
  stop_services >/dev/null 2>&1
  # -f matches the WHOLE command line, so a pattern that also appears in this
  # script's own argv would make pkill shoot the panel (and it does: that is how
  # this line was found). Kill the pids we recorded, then sweep for the rest by
  # name, excluding ourselves and our parent.
  local q
  for q in $(pgrep -f "nginx -c $NGX_CONF" 2>/dev/null); do kill "$q" 2>/dev/null || true; done
  for q in $(pgrep -f "$APP_FILE" 2>/dev/null); do
    [[ $q == $$ || $q == $PPID ]] && continue
    kill "$q" 2>/dev/null || true
  done
  sleep 1
  have_cmd termux-wake-unlock && termux-wake-unlock 2>/dev/null
  sleep 1

  step "Deleting website folders..."
  rm -rf "$SITES_DIR"

  step "Uninstalling nginx..."
  if have_cmd apt; then apt purge -y nginx >/dev/null 2>&1; apt autoremove --purge -y >/dev/null 2>&1; apt clean >/dev/null 2>&1; fi

  step "Removing leftover files and folders..."
  local p
  for p in "$PREFIX/etc/nginx" "$PREFIX/var/lib/nginx" "$PREFIX/var/log/nginx"; do rm -rf "$p"; done
  # Only if you also want the old WordPress stack gone:
  read -rp "  Also purge php, php-fpm and mariadb (the v1 stack)? [y/N]: " z
  if [[ $z =~ ^[Yy]$ ]]; then
    if have_cmd apt; then apt purge -y php php-fpm mariadb >/dev/null 2>&1; apt autoremove --purge -y >/dev/null 2>&1; fi
    for p in "$PREFIX/etc/php"* "$PREFIX/etc/my.cnf"* "$PREFIX/var/lib/mysql" "$PREFIX/var/lib/php"* \
             "$PREFIX/var/log/php"* "$PREFIX/tmp/mysql"* "$PREFIX/var/run/mysqld"*; do rm -rf "$p"; done
    ok "Old PHP + MariaDB stack removed."
  fi
  rm -rf "$DATA"
  (( del_backups )) && rm -rf "$BACKUP_DIR"
  hash -r

  step "Checking that everything is really gone..."
  local left=() c2
  for c2 in nginx php php-fpm mariadb mysql; do have_cmd "$c2" && left+=("command still present: $c2"); done
  for p in "$SITES_DIR" "$DATA" "$PREFIX/etc/nginx" "$PREFIX/var/lib/mysql"; do
    [[ -e $p ]] && left+=("folder still exists: $p")
  done
  (( del_backups )) && [[ -e $BACKUP_DIR ]] && left+=("folder still exists: $BACKUP_DIR")
  if have_cmd pgrep; then
    for c2 in nginx php-fpm mariadbd mysqld "server.mjs"; do
      pgrep -f "$c2" >/dev/null 2>&1 && left+=("process still running: $c2")
    done
  fi
  echo
  if (( ${#left[@]} == 0 )); then
    echo -e "${G}  ╔══════════════════════════════════════════════╗${N}"
    echo -e "${G}  ║   ✔  EVERYTHING IS CLEAN                     ║${N}"
    echo -e "${G}  ╚══════════════════════════════════════════════╝${N}"
    echo "   Removed: all websites + their SQLite databases, nginx, the app"
    echo "   bundle, the build tree, logs and panel data."
    (( del_backups == 0 )) && echo "   Kept: backups in $BACKUP_DIR"
    echo
    echo "   Run the panel again to start fresh."
  else
    warn "Wipe finished, but these remain:"
    local l; for l in "${left[@]}"; do echo "     - $l"; done
    echo "   (Run the wipe again, or remove them by hand.)"
  fi
  (( del_self )) && rm -f "$(readlink -f "$0")" && echo "   This script file was deleted too."
  echo
  exit 0
}

# ---------------------------------------------------------------------
#  MAIN MENU
# ---------------------------------------------------------------------
main_menu() {
  while true; do
    banner
    echo -e "${W}  ahmed web panel${N}"
    echo "  ─────────────────────────────────────────────"
    status_line
    echo -e "  ${D}app: $(app_ready && app_version || echo 'NOT BUILT')   node: $(node_label)${N}"
    echo "  ─────────────────────────────────────────────"
    echo -e "   ${Y}1.${N} See all websites"
    echo -e "   ${Y}2.${N} Add new website"
    echo -e "   ${Y}3.${N} Custom domains (add / check / edit / remove)"
    echo -e "   ${Y}4.${N} Delete website"
    echo -e "   ${Y}5.${N} Check environment (install nginx, node...)"
    echo -e "   ${Y}6.${N} Start / stop services"
    echo -e "   ${Y}7.${N} Update the app (rebuild + restart all sites)"
    echo -e "   ${R}8.${N} Full wipe (uninstall everything, start fresh)"
    echo -e "   ${Y}9.${N} Site actions (start/stop/log/backup/restore/creds)"
    echo -e "   ${Y}10.${N} Restore a backup"
    echo -e "   ${Y}11.${N} Roll the app back to the previous bundle"
    echo -e "   ${Y}0.${N} Exit  ${D}(services keep running)${N}"
    echo "  ─────────────────────────────────────────────"
    read -rp "  Choose an option: " opt
    case $opt in
      1) list_sites ;;
      2) add_site ;;
      3) manage_domains ;;
      4) delete_site ;;
      5) check_environment ;;
      6) services_menu ;;
      7) update_app ;;
      8) wipe_all ;;
      9) site_actions ;;
      10) restore_site ;;
      11) rollback_app ;;
      0) echo; exit 0 ;;
      *) err "Invalid option"; sleep 1 ;;
    esac
  done
}

require_termux
init_dirs
node_sqlite_setup 2>/dev/null || true
startup_check
main_menu
