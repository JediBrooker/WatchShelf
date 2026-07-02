# Exposing the WatchShelf sidecar

The watch talks to **only the sidecar** (login, browsing, downloads, progress) —
Audiobookshelf itself never has to be exposed to the internet. You just need the
sidecar reachable over **HTTPS on port 443 with a valid CA-signed cert** (the watch
rejects self-signed / plain HTTP / non-443 ports).

Two shapes, either works:

- **Shape A — dedicated subdomain** (recommended, simplest): `watchshelf.example.com`
  → the sidecar. No path games, no precedence rules. Log in on the watch with
  `https://watchshelf.example.com`.
- **Shape B — same-domain path**: `books.example.com/watchshelf-transcode` → the
  sidecar, co-located with your existing Audiobookshelf site. Log in with
  `https://books.example.com/watchshelf-transcode`.

The sidecar **self-strips** an optional `/watchshelf-transcode` prefix (see
`BASE_PATH` in `.env.example`), so Shape B works whether your proxy strips the
prefix itself or forwards it whole — pick whichever config below matches your setup.

Pick your proxy: [Cloudflare Tunnel](#cloudflare-tunnel-cloudflared) ·
[nginx](#nginx) · [Apache](#apache-httpd) · [Caddy](#caddy) · [Traefik](#traefik-v3)

---

## Cloudflare Tunnel (cloudflared)

TLS is terminated at Cloudflare's edge automatically — nothing to install or renew
on your host, and `cloudflared` opens no public port at all (outbound-only). A named
tunnel never buffers the response, and it has **no configurable read/response
timeout** once headers are sent, so the 60s+ `/transcode` stream is never cut off —
only `connectTimeout` (the initial dial) is bounded.

### Shape A — dedicated subdomain

One-time setup:
```
cloudflared tunnel login
cloudflared tunnel create watchshelf
cloudflared tunnel route dns watchshelf watchshelf.example.com
```

`~/.cloudflared/config.yml`:
```yaml
tunnel: watchshelf
credentials-file: /root/.cloudflared/<TUNNEL-UUID>.json

originRequest:
  # Dial-only timeout; does NOT bound the streamed response.
  connectTimeout: 30s
  # Keep-alives so a long stream isn't torn down mid-transcode.
  tcpKeepAlive: 30s
  keepAliveTimeout: 90s
  # Do NOT add "noHappyEyeballs" - it isn't a real cloudflared key (valid keys:
  # connectTimeout, tlsTimeout, tcpKeepAlive, noTLSVerify, keepAliveConnections,
  # keepAliveTimeout, httpHostHeader, originServerName, proxyType, http2Origin,
  # disableChunkedEncoding, bastionMode), and it's moot anyway since the origin
  # is a single loopback IPv4 address.

ingress:
  - hostname: watchshelf.example.com
    service: http://127.0.0.1:8081
  - service: http_status:404   # required catch-all, must be last
```

Validate, then run:
```
cloudflared tunnel ingress validate
cloudflared tunnel ingress rule https://watchshelf.example.com
cloudflared tunnel run watchshelf     # or: cloudflared service install
```

**Dashboard-managed instead:** Zero Trust → Networks → Tunnels → your tunnel →
Public Hostnames → Add a public hostname: Subdomain `watchshelf`, Domain
`example.com`, Path blank, Service **HTTP** → `127.0.0.1:8081`. Under *Additional
application settings → TCP*, set keep-alive timeout 90s. No "response timeout" field
exists (or is needed) — the edge streams the full response regardless.

### Shape B — same-domain path

**Important:** cloudflared cannot strip a path prefix — it forwards the full path
to the origin, and the sidecar self-strips it. The `/watchshelf-transcode` rule
**must come before** the ABS catch-all (cloudflared matches top-to-bottom, first
match wins).

`~/.cloudflared/config.yml`:
```yaml
tunnel: books
credentials-file: /root/.cloudflared/<TUNNEL-UUID>.json

originRequest:
  connectTimeout: 30s
  tcpKeepAlive: 30s
  keepAliveTimeout: 90s

ingress:
  # Must be listed FIRST - more specific rule wins.
  - hostname: books.example.com
    path: "^/watchshelf-transcode(/.*)?$"   # quoted: starts with ^
    service: http://127.0.0.1:8081          # sidecar

  # Your existing Audiobookshelf catch-all for the same host.
  - hostname: books.example.com
    service: http://127.0.0.1:13378         # <- your real ABS address

  - service: http_status:404
```

Validate the rule actually hits the sidecar (not ABS) before relying on it:
```
cloudflared tunnel ingress validate
cloudflared tunnel ingress rule https://books.example.com/watchshelf-transcode/some/file
cloudflared tunnel ingress rule https://books.example.com/some/abs/page   # must hit ABS
cloudflared tunnel run books
```

**Dashboard-managed instead:** add two Public Hostnames in this order (drag the
first one above the second): (1) `books.example.com`, Path (regex, not a glob) =
`^/watchshelf-transcode(/.*)?$` → HTTP `127.0.0.1:8081`; (2) `books.example.com`,
Path blank → HTTP `127.0.0.1:13378` (ABS). Re-verify with `cloudflared tunnel
ingress rule` after saving — dashboard path-matching semantics have shifted across
versions.

> `path` is a **regular expression** on both the file and dashboard surfaces, never
> a glob — don't use `watchshelf-transcode/*`.

---

## nginx

Portable across nginx 1.18+ (Ubuntu 22.04, Debian 12) through current — uses the
combined `listen 443 ssl http2;` form rather than the standalone `http2 on;`
directive, which only exists from nginx 1.25.1 onward and would fail `nginx -t` on
older installs. Run `certbot --nginx -d <hostname>` first so the referenced
`ssl_certificate` paths exist.

### Shape A — dedicated subdomain

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name watchshelf.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name watchshelf.example.com;

    ssl_certificate     /etc/letsencrypt/live/watchshelf.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/watchshelf.example.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:8081;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Live ffmpeg /transcode stream: do not buffer, do not time out early.
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_read_timeout      600s;
        proxy_send_timeout      600s;
        send_timeout            600s;  # client-facing write timeout (default 60s)
        chunked_transfer_encoding on;
    }
}
```

### Shape B — same-domain path

Paste into your **existing** `books.example.com` server block, above the ABS
`location /`. `^~` makes this win over any regex `location ~ ...` your ABS config
might already define — plain prefix-length matching alone isn't guaranteed to.

```nginx
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name books.example.com;

    ssl_certificate     /etc/letsencrypt/live/books.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/books.example.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # WatchShelf sidecar - MUST come before the ABS location below.
    location ^~ /watchshelf-transcode/ {
        proxy_pass http://127.0.0.1:8081/;   # trailing slash strips the prefix

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_read_timeout      600s;
        proxy_send_timeout      600s;
        send_timeout            600s;
        chunked_transfer_encoding on;
    }

    # Optional: make the bare (no trailing slash) URL work too.
    location = /watchshelf-transcode {
        return 308 https://$host/watchshelf-transcode/;
    }

    # Your EXISTING Audiobookshelf proxy - unchanged, must stay last.
    location / {
        proxy_pass http://127.0.0.1:13378;   # <- your real ABS upstream
        proxy_http_version 1.1;
        proxy_set_header Host       $host;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

After editing: `sudo nginx -t && sudo systemctl reload nginx` (reload, not restart,
so in-flight downloads aren't dropped).

---

## Apache (httpd)

Needs `mod_proxy`, `mod_proxy_http`, `mod_ssl`, `mod_headers` (`a2enmod proxy
proxy_http ssl headers`), optionally `mod_md` for automatic Let's Encrypt instead of
certbot.

### Shape A — dedicated subdomain

```apache
<VirtualHost *:80>
    ServerName watchshelf.example.com
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName watchshelf.example.com

    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/watchshelf.example.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/watchshelf.example.com/privkey.pem

    # ProxyTimeout = proxy<->backend timeout; TimeOut = frontend I/O timeout.
    # Both need real headroom for a 60s+ transcode.
    ProxyTimeout 1200
    TimeOut      1200

    ProxyPreserveHost On
    ProxyRequests Off

    # No "buffering off" directive needed: mod_proxy_http only buffers a full
    # response when it must compute Content-Length for the client. The sidecar's
    # /transcode response is chunked with no Content-Length, so it streams through
    # as it arrives. Do NOT set "SetEnv proxy-sendcl 1" (or force Content-Length)
    # on this route - that would force buffering the entire ffmpeg output first.
    ProxyPass        / http://127.0.0.1:8081/ flushpackets=on disablereuse=on timeout=1200
    ProxyPassReverse / http://127.0.0.1:8081/

    RequestHeader set X-Forwarded-Proto "https"
</VirtualHost>
```

### Shape B — same-domain path

`mod_proxy` matches the **longest prefix**, regardless of directive order, so the
sidecar rules below always beat the ABS `/` catch-all no matter where they sit in
the file. One trap: a `RedirectMatch` to normalize the bare `/watchshelf-transcode`
(no trailing slash) to the trailing-slash form **never fires** once a `ProxyPass`
rule exists for the same prefix (mod_proxy's URL-mapping hook outranks mod_alias's
redirect hook) — so add an explicit second `ProxyPass` for the bare path instead.

```apache
<VirtualHost *:80>
    ServerName books.example.com
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName books.example.com

    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/books.example.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/books.example.com/privkey.pem

    ProxyPreserveHost On
    ProxyRequests Off
    ProxyTimeout 1200
    TimeOut      1200

    # Two rules cover BOTH the bare URL (what you enter on the watch, no trailing
    # slash) and everything under it. Both map to the sidecar, which self-strips
    # the prefix either way.
    ProxyPass        /watchshelf-transcode  http://127.0.0.1:8081  flushpackets=on disablereuse=on timeout=1200
    ProxyPassReverse /watchshelf-transcode  http://127.0.0.1:8081
    ProxyPass        /watchshelf-transcode/ http://127.0.0.1:8081/ flushpackets=on disablereuse=on timeout=1200
    ProxyPassReverse /watchshelf-transcode/ http://127.0.0.1:8081/

    # Your existing Audiobookshelf catch-all - shorter prefix, never shadows the
    # rules above regardless of file order. Adjust the port to your real ABS.
    ProxyPass        / http://127.0.0.1:13378/
    ProxyPassReverse / http://127.0.0.1:13378/

    RequestHeader set X-Forwarded-Proto "https"
</VirtualHost>
```

Verify with `curl -v https://books.example.com/watchshelf-transcode` (no trailing
slash) and confirm it reaches the sidecar, not ABS.

---

## Caddy

Caddy gets automatic HTTPS for free — just use a real public hostname (not
`localhost`/an IP) with DNS pointed at the host and ports 80/443 reachable for the
ACME HTTP-01 challenge.

### Shape A — dedicated subdomain

```caddyfile
{
	email you@example.com

	# Optional safety net - Caddy has no default response-body timeout once a
	# stream starts, so this isn't strictly required for the 60s+ transcode.
	servers {
		timeouts {
			read_body   600s
			write       600s
			idle        600s
		}
	}
}

watchshelf.example.com {
	reverse_proxy 127.0.0.1:8081 {
		# Flush every chunk immediately - required so the live ffmpeg mp3
		# stream reaches the watch as it's produced, not all at once at the end.
		flush_interval -1

		# Only bounds the wait for response HEADERS, not the stream duration.
		transport http {
			response_header_timeout 120s
		}
	}
}
```

### Shape B — same-domain path

`handle`/`handle_path` blocks match in **file order** (first match wins) — Caddy
does not reorder by specificity. The WatchShelf block **must** come before the ABS
catch-all in the file.

```caddyfile
{
	email you@example.com
	servers {
		timeouts {
			read_body   600s
			write       600s
			idle        600s
		}
	}
}

books.example.com {
	# Must appear before the ABS catch-all below, or ABS will swallow every
	# /watchshelf-transcode request first.
	handle_path /watchshelf-transcode/* {
		reverse_proxy 127.0.0.1:8081 {
			flush_interval -1
			transport http {
				response_header_timeout 120s
			}
		}
	}

	# Your existing Audiobookshelf config - must stay after the block above.
	handle {
		reverse_proxy 127.0.0.1:13378
	}
}
```

Run `caddy validate --config Caddyfile` before deploying — the `servers > timeouts`
sub-block syntax has shifted slightly across Caddy 2.x releases.

---

## Traefik (v3)

TLS via an ACME `certResolver`. **If Traefik runs in a container** and the sidecar
runs on the bare host, `127.0.0.1:8081` inside the Traefik container is the
container itself, not the host — use `host.docker.internal:8081` (with
`extra_hosts: ["host.docker.internal:host-gateway"]`) or put the sidecar on the same
Docker network and address it by container name.

### Shape A — dedicated subdomain

`traefik.yml` (static config):
```yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        readTimeout: "900s"
        writeTimeout: "900s"   # covers the FULL response-write duration, not just idle gaps
        idleTimeout: "900s"

certificatesResolvers:
  le:
    acme:
      email: "you@example.com"
      storage: "/letsencrypt/acme.json"
      tlsChallenge: {}

providers:
  file:
    filename: "/etc/traefik/dynamic.yml"
    watch: true
```

`dynamic.yml` (dynamic config — `serversTransport` is dynamic-only in Traefik v3;
it does **not** belong in `traefik.yml`):
```yaml
http:
  routers:
    watchshelf:
      rule: "Host(`watchshelf.example.com`)"
      entryPoints: [websecure]
      service: watchshelf
      tls:
        certResolver: le
      # No buffering middleware attached.

  services:
    watchshelf:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8081"
        serversTransport: default   # explicit - don't rely on implicit defaulting
        responseForwarding:
          flushInterval: "1ms"      # flush streamed chunks immediately

  serversTransports:
    default:
      forwardingTimeouts:
        dialTimeout: "30s"
        responseHeaderTimeout: "900s"
        idleConnTimeout: "900s"
```

**Docker labels instead** (sidecar as a container on a shared network, not
publishing 8081 to the host):
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.watchshelf.rule=Host(`watchshelf.example.com`)"
  - "traefik.http.routers.watchshelf.entrypoints=websecure"
  - "traefik.http.routers.watchshelf.tls.certresolver=le"
  - "traefik.http.services.watchshelf.loadbalancer.server.port=8081"
  - "traefik.http.services.watchshelf.loadbalancer.responseforwarding.flushinterval=1ms"
  - "traefik.http.services.watchshelf.loadbalancer.serverstransport=default"
  - "traefik.http.serversTransports.default.forwardingTimeouts.dialTimeout=30s"
  - "traefik.http.serversTransports.default.forwardingTimeouts.responseHeaderTimeout=900s"
  - "traefik.http.serversTransports.default.forwardingTimeouts.idleConnTimeout=900s"
```

### Shape B — same-domain path

The sidecar router needs an explicit higher `priority` than the ABS catch-all —
don't rely on Traefik's automatic rule-length ordering.

`dynamic.yml`:
```yaml
http:
  routers:
    watchshelf-path:
      rule: "Host(`books.example.com`) && PathPrefix(`/watchshelf-transcode`)"
      priority: 100          # higher than the ABS router below
      entryPoints: [websecure]
      service: watchshelf
      tls:
        certResolver: le
      # Prefix forwarded whole - sidecar self-strips it. No buffering middleware.

    audiobookshelf:
      rule: "Host(`books.example.com`)"
      priority: 1            # lower - only matches when the path rule doesn't
      entryPoints: [websecure]
      service: audiobookshelf
      tls:
        certResolver: le

  services:
    watchshelf:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8081"
        serversTransport: default
        responseForwarding:
          flushInterval: "1ms"
    audiobookshelf:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:13378"   # <- your existing ABS internal address
        serversTransport: default

  serversTransports:
    default:
      forwardingTimeouts:
        dialTimeout: "30s"
        responseHeaderTimeout: "900s"
        idleConnTimeout: "900s"
```

`traefik.yml` static config is the same as Shape A. As new routers get added later,
keep priorities explicit and distinct rather than depending on the automatic
rule-length tiebreak.

---

## Verifying any of the above

Once deployed, confirm the sidecar answers on the URL you're about to enter on the
watch:
```
curl https://<your-chosen-url>/health      # -> ok
```
For Shape B, also confirm the existing ABS site still works normally afterward, and
that a bare (no trailing slash) URL reaches the sidecar rather than falling through
to ABS.
