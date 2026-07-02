#!/usr/bin/env bash
# WatchShelf sidecar installer.
#
# One-line install (recommended - keeps interactive prompts working):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/JediBrooker/WatchShelf/main/sidecar/install.sh)"
#
# What this does:
#   1. Clones (or updates) the WatchShelf repo and starts the sidecar with Docker -
#      asking where Audiobookshelf runs so it can reach it, no YAML editing by hand.
#   2. Walks you through exposing the sidecar over HTTPS with whichever reverse
#      proxy you already use (Cloudflare Tunnel / nginx / Apache / Caddy / Traefik).
#      For nginx/Apache/Caddy it creates a NEW, separate config file and always
#      asks before touching anything - your EXISTING Audiobookshelf config is
#      never edited.
#
# Safe to re-run - already-done steps are skipped or just repeated harmlessly.

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# tiny helpers
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
info()    { printf '%s\n' "$*"; }
ok()      { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()     { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; }
heading() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

# ask()/confirm() are called DIRECTLY (never as `x="$(ask ...)"`) so that `exit`
# on a broken/absent terminal actually ends the whole script - inside a $(...)
# command substitution, `exit` would only kill that subshell and the caller
# would silently get an empty string back. ask() hands its answer back via the
# global REPLY_VALUE instead of stdout for the same reason.
REPLY_VALUE=""
ask() {
  # ask <prompt> [default]  ->  sets $REPLY_VALUE
  local prompt="$1" default="${2:-}"
  if [ -n "$default" ]; then prompt="$prompt [$default]: "; else prompt="$prompt: "; fi
  if ! read -r -p "$prompt" REPLY_VALUE < /dev/tty; then
    err "No terminal available to ask questions - run this in an interactive shell."
    exit 1
  fi
  REPLY_VALUE="${REPLY_VALUE:-$default}"
}
confirm() {
  # confirm <prompt> -> exit 0 (yes) or 1 (no); default is No
  local prompt="$1" reply
  if ! read -r -p "$prompt [y/N]: " reply < /dev/tty; then
    err "No terminal available to ask questions - run this in an interactive shell."
    exit 1
  fi
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
# Only letters, digits, dots and hyphens, not starting with '-' (so it can
# never be mistaken for a flag by certbot/dig/etc), and must contain a dot
# (every use here expects a real subdomain, e.g. watchshelf.example.com) -
# just enough to keep user input inert once it's pasted into a config file
# or command line.
valid_hostname() {
  case "$1" in
    "") return 1 ;;
    -*) return 1 ;;
    *[!a-zA-Z0-9.-]*) return 1 ;;
  esac
  case "$1" in
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 1: install the sidecar
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/JediBrooker/WatchShelf.git"
INSTALL_DIR="${WATCHSHELF_DIR:-${HOME:-/opt}/watchshelf}"
SIDECAR_DIR="$INSTALL_DIR/sidecar"

clone_or_update_repo() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing checkout at $INSTALL_DIR..."
    if ! git -C "$INSTALL_DIR" pull --ff-only; then
      err "Couldn't update the existing checkout at $INSTALL_DIR (local changes, or its history has moved on)."
      err "Fix:  rm -rf $INSTALL_DIR   then re-run this installer."
      exit 1
    fi
  elif [ -e "$INSTALL_DIR" ]; then
    err "$INSTALL_DIR already exists but isn't a WatchShelf checkout (or a previous clone was interrupted)."
    err "Fix:  rm -rf $INSTALL_DIR   then re-run this installer."
    exit 1
  else
    info "Cloning into $INSTALL_DIR..."
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi
}

detect_abs_url() {
  heading "Where does Audiobookshelf run?"
  local abs_container=""
  if require_cmd docker; then
    abs_container="$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
      | awk -F'\t' 'tolower($1) ~ /audiobookshelf|^abs$/ || tolower($2) ~ /audiobookshelf/ {print $1; exit}' \
      || true)"
  fi

  if [ -n "$abs_container" ]; then
    ok "Found a container that looks like Audiobookshelf: $abs_container"
    if confirm "Use it? (the sidecar will join its Docker network and talk to it directly)"; then
      local net
      net="$(docker inspect "$abs_container" \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null \
        | head -1 || true)"
      if [ -z "$net" ]; then
        warn "Could not determine $abs_container's Docker network - falling back to manual setup."
      else
        ABS_URL="http://${abs_container}:13378"
        ABS_NETWORK="$net"
        return
      fi
    fi
  fi

  info "  1) Audiobookshelf runs on this same machine, but NOT in Docker"
  info "  2) Audiobookshelf runs in Docker on this machine (I'll ask for its container name)"
  info "  3) Audiobookshelf is already reachable at a public https:// address"
  ask "Pick 1, 2, or 3" "1"; local choice="$REPLY_VALUE"
  case "$choice" in
    2)
      ask "Audiobookshelf's container name" "audiobookshelf"; local name="$REPLY_VALUE"
      local net
      net="$(docker inspect "$name" \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null \
        | head -1 || true)"
      ABS_URL="http://${name}:13378"
      ABS_NETWORK="$net"
      if [ -z "$ABS_NETWORK" ]; then
        warn "Could not find a running container named '$name'."
        warn "Double-check the name and re-run this script if the sidecar can't reach Audiobookshelf."
      fi
      ;;
    3)
      ask "Audiobookshelf's full https:// address" "https://books.example.com"
      ABS_URL="$REPLY_VALUE"
      ABS_NETWORK=""
      ;;
    *)
      ABS_URL="http://host.docker.internal:13378"
      ABS_NETWORK=""
      ;;
  esac
}

bring_up_sidecar() {
  heading "Starting the sidecar"
  ( cd "$SIDECAR_DIR" && docker compose up -d --build )
  info "Waiting for it to come up..."
  local i=0
  until curl -fsS "http://127.0.0.1:8081/health" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      err "The sidecar didn't respond after 30 seconds."
      info "Check what went wrong with:  (cd $SIDECAR_DIR && docker compose logs)"
      exit 1
    fi
    sleep 1
  done
  ok "Sidecar is running (http://127.0.0.1:8081/health -> ok)"
}

# ---------------------------------------------------------------------------
# Step 2: expose the sidecar over HTTPS
# ---------------------------------------------------------------------------

# Best-effort DNS sanity check - warns rather than blocks, since it can't see
# every possible network setup (double-NAT, an existing tunnel, etc.).
check_dns() {
  local host="$1"
  if ! require_cmd dig; then
    warn "Can't check DNS automatically ('dig' not found) - make sure $host already points at this server before continuing."
    return 0
  fi
  local my_ip resolved
  my_ip="$(curl -fsS4 https://ifconfig.me 2>/dev/null || true)"
  resolved="$(dig +short "$host" 2>/dev/null | tail -1 || true)"
  if [ -z "$resolved" ]; then
    warn "$host doesn't resolve to anything yet. DNS changes can take a few minutes to a few hours."
    confirm "Continue anyway?" || return 1
  elif [ -n "$my_ip" ] && [ "$resolved" != "$my_ip" ]; then
    warn "$host currently resolves to $resolved, but this server's public IP looks like $my_ip."
    confirm "Continue anyway?" || return 1
  else
    ok "$host already points at this server."
  fi
  return 0
}

install_certbot() {
  # $1 = "nginx" or "apache" (the certbot plugin to install alongside it)
  local plugin_pkg="python3-certbot-$1"
  if require_cmd apt-get; then
    sudo apt-get update -y && sudo apt-get install -y certbot "$plugin_pkg"
  elif require_cmd dnf; then
    sudo dnf install -y certbot "$plugin_pkg"
  elif require_cmd yum; then
    sudo yum install -y certbot "$plugin_pkg"
  else
    err "Don't know how to install certbot on this system automatically."
    err "Install 'certbot' and '$plugin_pkg' yourself, then re-run this script."
    return 1
  fi
}

verify_and_report() {
  local sub="$1"
  info "Waiting a few seconds for the certificate/DNS to settle..."
  sleep 5
  local i=0
  until curl -fsS "https://${sub}/health" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 12 ]; then
      warn "https://${sub}/health isn't responding yet."
      info "That's normal right after a fresh certificate/DNS change - try again in a minute:"
      info "  curl https://${sub}/health"
      return 0
    fi
    sleep 5
  done
  ok "https://${sub}/health -> ok"
  heading "Done!"
  info "On the watch: Log in with ${BOLD}https://${sub}${RESET} and your Audiobookshelf username/password."
}

# ---- nginx -----------------------------------------------------------------

write_nginx_redirect_only() {
  local sub="$1" conf="$2"
  sudo tee "$conf" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${sub};
    return 301 https://\$host\$request_uri;
}
EOF
}
write_nginx_final() {
  local sub="$1" conf="$2"
  sudo tee "$conf" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${sub};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${sub};

    ssl_certificate     /etc/letsencrypt/live/${sub}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${sub}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_read_timeout      600s;
        proxy_send_timeout      600s;
        send_timeout            600s;
        chunked_transfer_encoding on;
    }
}
EOF
}

setup_nginx() {
  heading "nginx"
  if ! require_cmd nginx; then
    err "nginx doesn't seem to be installed - install it first, then re-run this script."
    return 1
  fi
  ask "Subdomain for the sidecar, e.g. watchshelf.yourdomain.com"; local sub="$REPLY_VALUE"
  valid_hostname "$sub" || { err "That doesn't look like a valid hostname (needs at least one dot, e.g. watchshelf.yourdomain.com)."; return 1; }

  local conf="/etc/nginx/sites-available/watchshelf"

  # Already have a cert for this exact hostname from a previous run? Skip
  # straight to the final config - no need to re-run certbot or briefly drop
  # back to a redirect-only page.
  if sudo test -f "/etc/letsencrypt/live/${sub}/fullchain.pem"; then
    ok "A certificate for $sub already exists - reusing it."
    write_nginx_final "$sub" "$conf"
    sudo ln -sf "$conf" /etc/nginx/sites-enabled/watchshelf
    sudo nginx -t
    sudo systemctl reload nginx
    verify_and_report "$sub"
    return 0
  fi

  info "This creates a NEW file at /etc/nginx/sites-available/watchshelf (your existing"
  info "Audiobookshelf config is not touched) and gets a free HTTPS certificate with"
  info "certbot for: $sub"
  confirm "Continue?" || { warn "Skipped."; return 0; }
  check_dns "$sub" || { warn "Fix DNS, then re-run and pick nginx again."; return 1; }

  write_nginx_redirect_only "$sub" "$conf"
  sudo ln -sf "$conf" /etc/nginx/sites-enabled/watchshelf
  sudo nginx -t
  sudo systemctl reload nginx

  require_cmd certbot || install_certbot nginx
  if ! sudo certbot --nginx -d "$sub"; then
    err "Certificate request failed - the plain-http redirect page is still live, but HTTPS isn't set up yet."
    err "Check that $sub already points at this server and that port 80 is reachable from the internet, then re-run and pick nginx again."
    return 1
  fi

  # certbot only fills in cert paths - it doesn't add the streaming/timeout
  # settings the sidecar needs, so write the complete config ourselves.
  write_nginx_final "$sub" "$conf"
  sudo nginx -t
  sudo systemctl reload nginx
  verify_and_report "$sub"
}

# ---- Apache ------------------------------------------------------------

write_apache_redirect_only() {
  local sub="$1" conf="$2"
  sudo tee "$conf" >/dev/null <<EOF
<VirtualHost *:80>
    ServerName ${sub}
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>
EOF
}
write_apache_final() {
  local sub="$1" conf="$2"
  sudo tee "$conf" >/dev/null <<EOF
<VirtualHost *:80>
    ServerName ${sub}
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName ${sub}

    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/${sub}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${sub}/privkey.pem

    ProxyTimeout 1200
    TimeOut      1200

    ProxyPreserveHost On
    ProxyRequests Off

    ProxyPass        / http://127.0.0.1:8081/ flushpackets=on disablereuse=on timeout=1200
    ProxyPassReverse / http://127.0.0.1:8081/

    RequestHeader set X-Forwarded-Proto "https"
</VirtualHost>
EOF
}

setup_apache() {
  heading "Apache"
  # a2enmod/a2ensite are Debian/Ubuntu-only wrapper scripts - if they're not
  # here, this is probably a RHEL/httpd-style box this script doesn't support yet.
  if ! require_cmd a2enmod; then
    err "This script's Apache automation only supports Debian/Ubuntu-style Apache (a2enmod/a2ensite)."
    err "RHEL/httpd-style Apache isn't supported by this script yet - see sidecar/GETTING_STARTED.md for the manual steps."
    return 1
  fi
  ask "Subdomain for the sidecar, e.g. watchshelf.yourdomain.com"; local sub="$REPLY_VALUE"
  valid_hostname "$sub" || { err "That doesn't look like a valid hostname (needs at least one dot, e.g. watchshelf.yourdomain.com)."; return 1; }

  local conf="/etc/apache2/sites-available/watchshelf.conf"

  if sudo test -f "/etc/letsencrypt/live/${sub}/fullchain.pem"; then
    ok "A certificate for $sub already exists - reusing it."
    write_apache_final "$sub" "$conf"
    sudo a2ensite watchshelf >/dev/null
    sudo apache2ctl configtest
    sudo systemctl reload apache2
    verify_and_report "$sub"
    return 0
  fi

  info "This enables Apache's proxy/ssl modules if needed, creates a NEW file at"
  info "/etc/apache2/sites-available/watchshelf.conf (your existing Audiobookshelf site is"
  info "not touched), and gets a free HTTPS certificate with certbot for: $sub"
  confirm "Continue?" || { warn "Skipped."; return 0; }
  check_dns "$sub" || { warn "Fix DNS, then re-run and pick Apache again."; return 1; }

  # Loading a NEW module requires a real restart (a reload alone won't load a
  # .so into the running process) - but only do that the first time. On a
  # re-run, the modules are already loaded, so skip straight past this with
  # no disruption to Apache's other sites.
  if sudo apache2ctl -M 2>/dev/null | grep -q 'proxy_module' \
    && sudo apache2ctl -M 2>/dev/null | grep -q 'proxy_http_module' \
    && sudo apache2ctl -M 2>/dev/null | grep -q 'ssl_module' \
    && sudo apache2ctl -M 2>/dev/null | grep -q 'headers_module'; then
    ok "Apache's proxy/ssl modules are already enabled."
  else
    sudo a2enmod proxy proxy_http ssl headers >/dev/null
    sudo systemctl restart apache2
  fi

  write_apache_redirect_only "$sub" "$conf"
  sudo a2ensite watchshelf >/dev/null
  sudo systemctl reload apache2

  require_cmd certbot || install_certbot apache
  if ! sudo certbot --apache -d "$sub"; then
    err "Certificate request failed - the plain-http redirect page is still live, but HTTPS isn't set up yet."
    err "Check that $sub already points at this server and that port 80 is reachable from the internet, then re-run and pick Apache again."
    return 1
  fi

  write_apache_final "$sub" "$conf"
  sudo apache2ctl configtest
  sudo systemctl reload apache2
  verify_and_report "$sub"
}

# ---- Caddy ---------------------------------------------------------------

setup_caddy() {
  heading "Caddy"
  if ! require_cmd caddy; then
    err "Caddy doesn't seem to be installed - install it first: https://caddyserver.com/docs/install"
    return 1
  fi
  ask "Subdomain for the sidecar, e.g. watchshelf.yourdomain.com"; local sub="$REPLY_VALUE"
  valid_hostname "$sub" || { err "That doesn't look like a valid hostname (needs at least one dot, e.g. watchshelf.yourdomain.com)."; return 1; }

  local caddyfile="/etc/caddy/Caddyfile"
  local already=0
  if [ -f "$caddyfile" ]; then
    # Matches "sub.example.com {" (brace on the same line) OR a line that is
    # ONLY the hostname (brace on the next line) - anchored so a hostname
    # that's merely a substring/prefix of a different, unrelated block can't
    # produce a false match.
    if sudo grep -qE "^${sub}[[:space:]]*\{" "$caddyfile" 2>/dev/null \
      || sudo grep -qxF "$sub" "$caddyfile" 2>/dev/null; then
      already=1
    fi
  fi

  if [ "$already" -eq 1 ]; then
    ok "$caddyfile already has a block for $sub - nothing to change."
  else
    info "This appends a NEW block to $caddyfile for: $sub"
    info "(nothing already in that file is touched - only new lines are added at the end)"
    confirm "Continue?" || { warn "Skipped."; return 0; }
    check_dns "$sub" || { warn "Fix DNS, then re-run and pick Caddy again."; return 1; }
    { printf '\n%s {\n    reverse_proxy 127.0.0.1:8081 {\n        flush_interval -1\n    }\n}\n' "$sub"; } \
      | sudo tee -a "$caddyfile" >/dev/null
    sudo systemctl reload caddy 2>/dev/null || sudo caddy reload --config "$caddyfile"
  fi
  verify_and_report "$sub"
}

# ---- Traefik / Cloudflare Tunnel (instructions only - see comments below) --

setup_traefik() {
  heading "Traefik"
  ask "Subdomain for the sidecar, e.g. watchshelf.yourdomain.com"; local sub="$REPLY_VALUE"
  valid_hostname "$sub" || { err "That doesn't look like a valid hostname (needs at least one dot, e.g. watchshelf.yourdomain.com)."; return 1; }
  cat <<EOF

Traefik needs a label added to the sidecar's service in your EXISTING
docker-compose.yml - since that file also runs Traefik itself (and probably
other things), this script won't edit it automatically. Add this under the
sidecar service's "labels:" (matching whatever certresolver name your other
services already use, if it isn't "le"):

  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.watchshelf.rule=Host(\`${sub}\`)"
    - "traefik.http.routers.watchshelf.entrypoints=websecure"
    - "traefik.http.routers.watchshelf.tls.certresolver=le"
    - "traefik.http.services.watchshelf.loadbalancer.server.port=8081"
    - "traefik.http.services.watchshelf.loadbalancer.responseforwarding.flushinterval=1ms"

Then run:  docker compose up -d   (in that file's directory)

EOF
  info "Once that's applied, verify with:  curl https://${sub}/health"
}

setup_cloudflare() {
  heading "Cloudflare Tunnel"
  ask "Subdomain for the sidecar, e.g. watchshelf.yourdomain.com"; local sub="$REPLY_VALUE"
  valid_hostname "$sub" || { err "That doesn't look like a valid hostname (needs at least one dot, e.g. watchshelf.yourdomain.com)."; return 1; }
  local first_label="${sub%%.*}" rest_domain="${sub#*.}"

  # cloudflared very often runs in its OWN container (or even a different
  # host on the LAN) rather than directly on this machine - in that case
  # "127.0.0.1" means "inside the cloudflared container," not this server,
  # and can never reach the sidecar. Ask, and use the real LAN IP instead
  # when that's the case.
  local svc_url="127.0.0.1:8081"
  if confirm "Does cloudflared run in its own container or a different machine (not directly on this server)?"; then
    local lan_ip
    lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$lan_ip" ]; then
      svc_url="${lan_ip}:8081"
      ok "Using this server's LAN IP for the URL: $lan_ip"
    else
      warn "Couldn't auto-detect this server's LAN IP - run 'ip a' and use the address"
      warn "under the network interface that isn't 'lo', instead of 127.0.0.1 below."
    fi
  fi

  cat <<EOF

This part is done in the Cloudflare dashboard - no file to edit here:

  1. Go to https://one.dash.cloudflare.com -> Networks -> Tunnels.
  2. Open the tunnel already running on this server (or create one if you
     don't have one yet - the dashboard walks you through installing cloudflared).
  3. Open its "Public Hostnames" tab -> "Add a public hostname":
       Subdomain: ${first_label}
       Domain:    ${rest_domain}
       Path:      (leave blank)
       Type:      HTTP
       URL:       ${svc_url}
  4. Save. Cloudflare issues the certificate and DNS record automatically.

EOF
  info "Once that's done, verify with:  curl https://${sub}/health"
}

proxy_menu() {
  heading "Step 2: expose the sidecar over HTTPS"
  info "Pick whichever you already use to reach Audiobookshelf from outside your network:"
  info "  1) Cloudflare Tunnel"
  info "  2) nginx"
  info "  3) Apache"
  info "  4) Caddy"
  info "  5) Traefik"
  info "  6) I don't have one yet / not sure"
  ask "Pick 1-6"; local choice="$REPLY_VALUE"
  case "$choice" in
    1) setup_cloudflare || true ;;
    2) setup_nginx || true ;;
    3) setup_apache || true ;;
    4) setup_caddy || true ;;
    5) setup_traefik || true ;;
    *)
      info "No reverse proxy yet? Caddy is the easiest to set up from scratch - it fetches"
      info "its own free HTTPS certificate automatically. Install it"
      info "(https://caddyserver.com/docs/install), re-run this script, and pick option 4."
      ;;
  esac
}

# ---------------------------------------------------------------------------
main() {
  heading "WatchShelf sidecar installer"
  info "This installs and starts the sidecar with Docker, then helps you expose it"
  info "over HTTPS so your watch can reach it. Nothing outside a new 'watchshelf'"
  info "folder and (optionally, with your confirmation) a couple of new,"
  info "separate config files gets touched."

  for c in git curl; do
    require_cmd "$c" || { err "'$c' is required - install it, then re-run this script."; exit 1; }
  done
  require_cmd docker || { err "Docker is required. Install it first: https://docs.docker.com/get-docker/"; exit 1; }
  docker compose version >/dev/null 2>&1 || { err "'docker compose' (v2) is required - update Docker, then re-run."; exit 1; }

  heading "Step 1: install the sidecar"
  clone_or_update_repo

  ABS_URL=""
  ABS_NETWORK=""
  detect_abs_url

  printf 'ABS_URL=%s\n' "$ABS_URL" > "$SIDECAR_DIR/.env"
  ok "Sidecar configured to reach Audiobookshelf at: $ABS_URL"

  if [ -n "$ABS_NETWORK" ]; then
    cat > "$SIDECAR_DIR/docker-compose.override.yml" <<EOF
services:
  watchshelf-sidecar:
    networks:
      - abs_net
networks:
  abs_net:
    name: ${ABS_NETWORK}
    external: true
EOF
  else
    rm -f "$SIDECAR_DIR/docker-compose.override.yml"
  fi

  bring_up_sidecar
  proxy_menu
}

main "$@"
