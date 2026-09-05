# VPS and Nginx Architecture

Prepared, not provisioned. Nothing here has been executed and no Hostinger
account has been contacted.

## Target shape

```
                     ┌────────────────────────────┐
   qirsh.site  ─────▶│                            │──▶ /var/www/qirsh-site
   www.qirsh.site    │   Nginx  (80 → 443, TLS)   │    static files, no runtime
                     │                            │
   admin.qirsh.site ─│                            │──▶ 127.0.0.1:3001
                     └────────────────────────────┘    Next.js under systemd
```

Two server blocks, one certificate covering three names, one Node process bound
to **loopback only** so the admin app is reachable exclusively through Nginx.

## VPS requirements

The public site is static and costs nothing to serve. The sizing is entirely
driven by the Next.js admin build.

| Resource | Minimum | Recommended | Why |
|---|---|---|---|
| Plan | KVM 1 | **KVM 2** | `next build` is the peak; 1 vCPU/4 GB works but builds slowly |
| RAM | 2 GB (+2 GB swap) | **4 GB** | `next build` can exceed 1.5 GB. With 2 GB and no swap it gets OOM-killed — a confusing failure that looks like a code error |
| vCPU | 1 | 2 | |
| Disk | 20 GB | 40 GB | OS + Node + `node_modules` + build cache + logs |
| OS | **Ubuntu 24.04 LTS** | | as specified |
| Location | closest to users | | Gulf/Europe |

**Build off the box if you can.** Building on a 1-vCPU VPS while it also serves
traffic is the usual cause of a mysterious deploy failure. Either build locally
and upload `.next/`, or accept a slower deploy on KVM 2.

## Software

```
nginx           reverse proxy + TLS + static
nodejs 20 LTS   pinned; Next 14.2 needs >= 18.17
certbot         Let's Encrypt, with the nginx plugin
ufw             22, 80, 443 only
fail2ban        SSH brute-force
```

Node 20 explicitly, because `admin/package.json` pins no `engines` field — an
unpinned runtime can move under a working deployment during a routine upgrade.

## Nginx — public site

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name qirsh.site www.qirsh.site;
    return 301 https://qirsh.site$request_uri;   # also collapses www
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name www.qirsh.site;
    # certificate directives added by certbot
    return 301 https://qirsh.site$request_uri;   # one canonical host
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name qirsh.site;

    root /var/www/qirsh-site;
    index index.html;

    # Directory-style output: /privacy -> /privacy/index.html.
    # This serves it WITHOUT a redirect, so /privacy returns 200 directly —
    # unlike the current Workers host, which 307s to /privacy/.
    location / {
        try_files $uri $uri/ $uri/index.html =404;
    }

    location = /favicon.png      { expires 7d; access_log off; }
    location ~* \.(png|jpg|svg|ico|woff2)$ { expires 30d; add_header Cache-Control "public"; }
    location ~* \.html$          { add_header Cache-Control "public, max-age=0, must-revalidate"; }

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_types text/css text/html application/javascript image/svg+xml;
}
```

`try_files` matters: it makes `/privacy` return **200** rather than redirecting.
See [`legal_url_migration.md`](legal_url_migration.md) — this is a behaviour
change from the current host and it is the better one.

## Nginx — admin

```nginx
limit_req_zone $binary_remote_addr zone=adminlogin:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=adminapi:10m   rate=60r/m;

server {
    listen 80;
    server_name admin.qirsh.site;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name admin.qirsh.site;

    # Keep the admin surface out of every index, belt and braces with robots.txt.
    add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options           "DENY" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header Referrer-Policy           "no-referrer" always;

    client_max_body_size 10m;

    location = /robots.txt {
        add_header Content-Type text/plain;
        return 200 "User-agent: *\nDisallow: /\n";
    }

    location /login { limit_req zone=adminlogin burst=5 nodelay; proxy_pass http://127.0.0.1:3001; include /etc/nginx/proxy_admin.conf; }
    location /api/  { limit_req zone=adminapi  burst=20 nodelay; proxy_pass http://127.0.0.1:3001; include /etc/nginx/proxy_admin.conf; }
    location /      { proxy_pass http://127.0.0.1:3001; include /etc/nginx/proxy_admin.conf; }
}
```

`/etc/nginx/proxy_admin.conf`:

```nginx
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;   # required, or Secure cookies break
proxy_set_header Upgrade           $http_upgrade;
proxy_set_header Connection        "upgrade";
proxy_read_timeout 60s;
```

`X-Forwarded-Proto` is not optional. Without it the app believes it is on plain
HTTP and may issue session cookies without the `Secure` flag — a real weakening
that is invisible until someone inspects the cookie.

## systemd unit for the admin app

```ini
# /etc/systemd/system/qirsh-admin.service
[Unit]
Description=Qirsh Admin (Next.js)
After=network.target

[Service]
Type=simple
User=qirsh
WorkingDirectory=/srv/qirsh-admin
Environment=NODE_ENV=production
Environment=PORT=3001
EnvironmentFile=/etc/qirsh/admin.env      # root:qirsh 0640 — holds the service-role key
ExecStart=/usr/bin/node node_modules/.bin/next start --port 3001
Restart=on-failure
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/srv/qirsh-admin/.next

[Install]
WantedBy=multi-user.target
```

Bound to `127.0.0.1:3001` by Nginx's `proxy_pass`; confirm Next is not listening
on `0.0.0.0`, or the admin app is reachable on port 3001 bypassing every header
and rate limit above. `ufw` closing 3001 is the second layer.

## TLS

```bash
certbot --nginx -d qirsh.site -d www.qirsh.site -d admin.qirsh.site
```

One certificate, three names. DNS for all three must resolve to the VPS **before**
running this — certbot proves control over each name over HTTP.

## Deploying the public site

```bash
ADMOB_PUBLISHER_ID=pub-… python3 tools/build_site.py   # writes build/site/
tools/deploy_site.sh                                   # fail-closed preflight, then rsync
```

**Do not hand-run the rsync.** `--delete` makes the server match the build
exactly, and `app-ads.txt` is only emitted when `ADMOB_PUBLISHER_ID` is set — a
rebuild without it silently deleted the live file. `tools/deploy_site.sh` refuses
to deploy an incomplete tree; `--preflight-only` checks without deploying.

`--delete` keeps the server identical to the build. The generator is
standard-library-only, so no toolchain has to exist on the VPS.

## Order of operations

1. Provision the VPS, harden SSH, `ufw` 22/80/443.
2. Install nginx, Node 20, certbot.
3. Point DNS ([`dns_plan.md`](dns_plan.md)) and wait for propagation.
4. Deploy the static site; serve it over HTTP first and confirm all four routes.
5. `certbot` for all three names.
6. Deploy the admin app, systemd unit, env file, verify login and the
   `admin_users` gate against a non-admin account.
7. **Only then** the legal URL migration
   ([`legal_url_migration.md`](legal_url_migration.md)).

Do not start step 7 before step 5 is verified, and do not point the app's legal
URLs anywhere until `qirsh.site/privacy` and `/terms` are independently confirmed.
