# Getting started: setting up the sidecar

This is a step-by-step guide to go from **"I have Audiobookshelf running"** to
**"my watch can browse and download books."** No prior experience with servers or
networking needed.

## Why do I need this "sidecar" thing at all?

Your Audiobookshelf library stores each audiobook as **one big file** — often
several hundred megabytes, sometimes close to a full gigabyte for a long book.

Your Garmin watch is a tiny computer built for tracking steps and heart rate, not
downloading big files. When it tries to download a whole audiobook in one go, it
just gives up (you'll see "Download Failed"). Even just *asking what's inside* a
long book can be too much information for the watch to handle in one answer
("could not load book").

The **sidecar** is a small helper program that fixes this by sitting in between
your watch and Audiobookshelf:

- when your watch asks for a book, the sidecar slices it into small ~30-minute
  pieces on the fly (about 14 MB each — easy for the watch), instead of handing
  over the whole gigabyte at once;
- when your watch asks "what's in my library", the sidecar sends a short summary
  instead of everything Audiobookshelf knows about every book.

Think of it like posting a large parcel through a small letterbox: the box itself
won't fit, but if someone unpacks it into a few smaller envelopes first, each one
slides through fine. The sidecar is that unpacking step.

**Bonus:** because the sidecar handles login too, your actual Audiobookshelf
server never has to be exposed to the internet — only the small sidecar does.

## The big picture

You're doing three things, in order:

1. **Install the sidecar** next to Audiobookshelf (one command — below).
2. **Give the sidecar a normal web address** (`https://something.yourdomain.com`)
   using whatever you already use to do that for other things on your server —
   pick your tool below.
3. **Log into the watch** using that new web address.

That's it. Let's go.

> **Shortcut:** there's a single command that does everything below for you -
> installs the sidecar, asks where Audiobookshelf runs, and then walks you
> interactively through Step 2 for whichever proxy you use:
> ```
> bash -c "$(curl -fsSL https://raw.githubusercontent.com/JediBrooker/WatchShelf/main/sidecar/install.sh)"
> ```
> It's safe to re-run, and for nginx/Apache/Caddy it always asks before touching
> anything and only ever creates a *new*, separate file - it never edits your
> existing Audiobookshelf config. Keep reading if you'd rather do it by hand, or
> want to understand what each step actually does first.

## Step 1 — Install the sidecar

This part is the same no matter which proxy tool you use below.

**You'll need:** [Docker](https://docs.docker.com/get-docker/) installed on the
same machine (or same network) as your Audiobookshelf server.

1. Get the WatchShelf code and go into the `sidecar` folder:
   ```
   git clone https://github.com/JediBrooker/WatchShelf
   cd WatchShelf/sidecar
   ```

2. Open `docker-compose.yml` in any text editor and change the one line that says
   `ABS_URL=...` to point at your Audiobookshelf server. Which value to use
   depends on where Audiobookshelf runs — the file has examples for the three
   common cases (ABS on the same machine, ABS in its own Docker container, or ABS
   already reachable at a public web address); pick the one that matches your
   setup.

3. Start it:
   ```
   docker compose up -d --build
   ```

4. Check it's alive (run this on the same machine):
   ```
   curl http://127.0.0.1:8081/health
   ```
   You should see exactly: `ok`. If you see nothing or an error, the sidecar
   didn't start — check `docker compose logs` for what went wrong before moving on.

   *(This only proves the sidecar is running on your server — it isn't reachable
   from the internet, or from your watch, yet. That's the next step.)*

## Step 2 — Give the sidecar a web address

Pick whichever one of these you already use for Audiobookshelf itself (or for any
other website on your server) — you don't need to install a new one:

- [Cloudflare Tunnel](#cloudflare-tunnel)
- [nginx](#nginx)
- [Apache](#apache)
- [Caddy](#caddy)
- [Traefik](#traefik)

Not sure which one you have? Look at how you already reach Audiobookshelf from
outside your home — whatever makes that work is the one to use here too.

---

## Cloudflare Tunnel

Your sidecar is already running on your server at `127.0.0.1:8081`. Now you just need to give it a real web address so your watch can reach it. You'll do this with **Cloudflare Tunnel** — a free Cloudflare feature that safely exposes something on your server to the internet, using a dashboard (no config files to edit).

Before you start, you need two things already in place (if you're not sure, check now):
- A Cloudflare account (free to make at cloudflare.com if you don't have one).
- A domain name added to your Cloudflare account (e.g. `example.com`). If you don't have a domain in Cloudflare yet, you'll need to add one first — Cloudflare's own "Add a site" flow walks you through it — since step 3 below needs a domain to already be there to pick from.

1. **Go to https://one.dash.cloudflare.com and log in.** This is a separate dashboard from your normal Cloudflare account page ("Zero Trust" is just Cloudflare's name for this section), but you log in with the same Cloudflare email and password. Once logged in, click **Networks** in the left menu, then **Tunnels**.

2. **Check whether a tunnel already exists for your server.** You likely already have one, since it's probably how you expose ABS itself to the internet. Look at the list of tunnels shown on the page — each one has a name you chose earlier and a status dot (green = connected/running, grey = not connected). If you see one you recognize (e.g. named after your server or "abs"), click into it and skip to step 3.
   - If the list is empty, or you don't recognize any tunnel: click **Create a tunnel**, give it any name (e.g. `my-server`), and it will show you a one-line install command. Open a terminal on the same physical machine (or VM) where ABS and the sidecar are running — the same machine you used to install Docker and start the sidecar — and paste that command in. It installs and starts a small background program called `cloudflared` that connects your server to Cloudflare. Wait about 10-30 seconds, then go back to the Tunnels list in the dashboard: your new tunnel's status dot should turn green, meaning it's connected. Don't continue to step 3 until you see green.

3. Click into that tunnel, then open the **Public Hostnames** tab, and click **Add a public hostname**. Fill in:
   - **Subdomain**: `watchshelf` (or any name you like — this becomes part of your web address)
   - **Domain**: pick your own domain from the dropdown (this is the domain you already own and manage in Cloudflare — see the prerequisite note above if nothing appears here)
   - **Path**: leave this blank
   - **Type**: `HTTP`
   - **URL**: `127.0.0.1:8081` in almost every case — **except** if `cloudflared` itself runs in
     its *own* Docker container (rather than directly on the server), in which case
     `127.0.0.1` means "inside the cloudflared container," not your server, and can't
     reach the sidecar. If that's your setup, use the server's own LAN IP instead
     (e.g. `192.168.1.50:8081` — find yours with `ip a` on the server, look under the
     network interface that isn't `lo`).

4. Click **Save**. Cloudflare automatically does two things for you in the background: it issues an **HTTPS certificate** (this is what makes your address start with `https://` and show as secure, instead of the unencrypted `http://`), and it creates a **DNS record** (this is the internet's phonebook entry that points `watchshelf.<your-domain>` at your Cloudflare tunnel). You don't need to do anything for either of these — no YAML file to touch, no server restart needed. It can take a minute or two for this to fully take effect, so wait about a minute before testing in the next step.

5. **Verify it worked.** Open a terminal and run (replace `<your-domain>` with the domain you picked in step 3):
   ```
   curl https://watchshelf.<your-domain>/health
   ```
   You can also just open `https://watchshelf.<your-domain>/health` in a browser. (This `/health` address is a built-in check that the sidecar you already installed responds to automatically — you don't need to set anything up for it.)
   - **Success**: the output is exactly `ok`.
   - **Failure** (timeout or error page): first, if it's only been a few seconds since you clicked Save in step 4, wait a minute and try again — the certificate/DNS setup needs a short time to finish. If it still fails after that, the most common causes are: the Public Hostname pointing at the wrong port (it must be `8081`, the sidecar — not ABS's own port); the tunnel's status dot showing grey/not connected in the dashboard; or — if you used your server's LAN IP in step 3 because `cloudflared` runs in its own container — an out-of-date sidecar still only listening on `127.0.0.1`. If it's the last one: on the server, run `docker compose up -d` again in the `sidecar` folder to pick up the current config, which listens on all interfaces.

Once you see `ok`, type `https://watchshelf.<your-domain>` into your watch app and you're done.

---

**Advanced/optional, only if this already applies to you:** If you're the kind of person who already manages your Cloudflare Tunnel by hand-editing a `config.yml` file on your server instead of using the dashboard, you can add the sidecar the same way — as another `hostname`/`service` entry pointing at `127.0.0.1:8081` — and just restart `cloudflared`. This is only relevant if you're already doing it that way; everyone else should stick to the dashboard method above, since it needs no file edits or restarts.

---

## nginx

Your sidecar is already running on your server, answering requests at `127.0.0.1:8081` (that just means "only reachable from inside the server itself"). Below, you'll put nginx (a program that's already installed on your server) in front of it so it gets a real `https://` web address you can type into the Garmin watch app.

You'll need to know your server's public IP address (the number you use to reach your server from the internet) and you'll need to pick a subdomain name, e.g. `watchshelf.yourdomain.com` (using a domain you already own).

0. **Get a terminal connected to your server.** Every step below says "on the server, run..." — here's how to get there:
   - If your server is a **VPS / cloud box** (DigitalOcean, Linode, Hetzner, AWS, etc.): open Terminal (Mac/Linux) or PowerShell/PuTTY (Windows) on your own computer and run `ssh yourusername@your-server-ip` (your hosting provider's dashboard shows you this username and IP, and you'd have set a password or SSH key when you created the server).
   - If your server is a **Raspberry Pi**: either SSH into it the same way (`ssh pi@its-ip-address`), or if you have a monitor/keyboard plugged directly into it, just open the terminal app on its desktop.
   - If your Audiobookshelf/sidecar runs on a **NAS** (Synology, QNAP, etc.): most NAS devices let you enable SSH in their web admin settings, then you SSH into it the same way as above. If you can't find an SSH option, this guide assumes you can get a terminal one way or another — check your NAS's documentation for "enable SSH access."
   You'll know you're in the right place once connected: run `curl 127.0.0.1:8081` and it should respond with something (not "connection refused"), confirming you're on the same machine as the sidecar.

   Also, a couple of the commands below start with `sudo`. That means "run this as an administrator." The first time you use it in a session, it will ask for **your own login password** for this server (not a new password, and typing it won't show any characters on screen — that's normal, just type it and press Enter).

1. **Point a subdomain at your server.** First, find your server's public IP address by running this on the server:
   ```
   curl -4 ifconfig.me
   ```
   That will print a number like `203.0.113.42` — that's your server's public IP. Then log in to wherever you manage DNS for your domain (e.g. Cloudflare, Namecheap, GoDaddy — this is the site where you bought/manage your domain name) and add an "A record": Name = `watchshelf` (or whatever you want), Value = the IP address you just found. This has to be done first and takes a few minutes to a few hours to take effect.

2. **Make sure certbot is installed** (this is the tool that gets you a free HTTPS certificate). On the server, run:
   ```
   sudo apt install certbot python3-certbot-nginx
   ```
   If it says already installed, that's fine, move on.

   **If you get an error like "command not found: apt"**, your server isn't Ubuntu/Debian. This guide only covers apt-based servers step-by-step. Common alternatives: on Fedora/CentOS/Rocky, try `sudo dnf install certbot python3-certbot-nginx` instead; on a Synology/QNAP NAS, install certbot via your NAS's package manager (Synology Package Center, QNAP App Center) or its built-in "Certificate" settings, which can issue Let's Encrypt certificates without certbot at all. If none of those match your system, search "install certbot on [your server type]" for the exact command, then continue with step 3 below.

3. **Create the config file.** On the server, run:
   ```
   sudo nano /etc/nginx/sites-available/watchshelf
   ```
   This opens `nano`, a simple text editor that runs right inside your terminal (it's not a separate window — the terminal itself becomes the editor). To paste the block below into it: on Mac Terminal, use Cmd+V; on most Linux terminals, use Ctrl+Shift+V; on Windows Terminal/PuTTY, right-click usually pastes. If nothing happens when you paste, try the other shortcut for your terminal app, or use your terminal's menu (Edit > Paste).

   Paste in the block below, then replace **every occurrence** of `watchshelf.example.com` with the real subdomain you created in step 1 (e.g. `watchshelf.yourdomain.com`):

   ```nginx
   server {
       listen 80;
       listen [::]:80;
       server_name watchshelf.example.com;
       return 301 https://$host$request_uri;
   }
   ```
   Save and exit for now: press `Ctrl+O`, then `Enter`, then `Ctrl+X`. (You'll add the second half of this config, the `https://` part, in step 5 — we're doing it in two steps on purpose, explained below.)

4. **Turn on the config and open it up to the internet.** Run these one at a time:
   ```
   sudo ln -s /etc/nginx/sites-available/watchshelf /etc/nginx/sites-enabled/
   sudo nginx -t
   sudo systemctl reload nginx
   ```
   `nginx -t` should print `syntax is ok` and `test is successful` — if so, you're good, move to step 4b.

   **If `ln` says "File exists"**: that's harmless — it just means the symlink is already there from an earlier attempt. Ignore that message and continue to `nginx -t`.

   4b. **Now get your free HTTPS certificate.** Run, replacing `watchshelf.example.com` with your real subdomain:
   ```
   sudo certbot --nginx -d watchshelf.example.com
   ```
   Certbot will ask for an email and to accept terms — answer its prompts. Certbot is smart enough to see you only have a plain port-80 (non-HTTPS) config so far, issue the certificate, and it will then offer to automatically edit your config to add the HTTPS part for you — accept that. This two-step order (plain http first, then certbot adds https) avoids a chicken-and-egg problem: if the https config block existed first, nginx would refuse to even start because it would be pointing at certificate files that don't exist yet.

   **If certbot fails with a DNS-related error** ("Could not validate domain" or similar), your subdomain hasn't finished propagating yet from step 1 — wait 15-30 minutes and retry the same `certbot --nginx -d watchshelf.example.com` command. **If it fails with a port/connection error**, make sure nothing else (a firewall, or your hosting provider's dashboard) is blocking incoming traffic on port 80.

5. **Double check the finished config.** Certbot has now added HTTPS settings to your file. Open it again to confirm it looks right and to add a few extra lines that make audiobook downloads reliable:
   ```
   sudo nano /etc/nginx/sites-available/watchshelf
   ```
   You should now see a second `server` block that certbot added, listening on port 443 with `ssl_certificate` lines pointing at real files under `/etc/letsencrypt/live/...`. Inside that block's `location / { ... }` section, make sure it matches this (add/edit lines so it does), replacing `watchshelf.example.com` with your real subdomain everywhere in the file:

   ```nginx
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
           proxy_buffering         off;
           proxy_request_buffering off;
           proxy_read_timeout      600s;
           proxy_send_timeout      600s;
           send_timeout            600s;
           chunked_transfer_encoding on;
       }
   }
   ```
   (The `proxy_buffering off` and `600s` timeout lines stop a long audiobook download from getting cut off partway through — don't remove them.)

   Save and exit: `Ctrl+O`, then `Enter`, then `Ctrl+X`. Then test and reload again:
   ```
   sudo nginx -t
   sudo systemctl reload nginx
   ```
   `nginx -t` should print `syntax is ok` and `test is successful`. If it prints anything else, re-open the file and check you replaced the domain name correctly everywhere, then repeat this step.

6. **Verify it worked.** From any computer (doesn't have to be the server), run:
   ```
   curl https://watchshelf.example.com/health
   ```
   (replace with your real subdomain).

   **Success** = it prints exactly `ok`.

   **Failure, and how to tell what's wrong:**
   - `curl: (7) Failed to connect` or a timeout → this is a DNS or nginx problem: double-check step 1 (DNS record correct? has it had time to propagate?), then re-check step 4/5 (`nginx -t` passed and you reloaded).
   - An HTML error page (like nginx's default "404 Not Found" or "502 Bad Gateway") → nginx is reachable but can't reach your sidecar. Confirm the sidecar container is still running and actually listening on `127.0.0.1:8081` (re-check the sidecar setup from before this guide).
   - Connects fine but doesn't print exactly `ok` (e.g. prints nothing, or different text, or a connection-refused specifically from the sidecar rather than nginx) → this most likely means your sidecar doesn't have a `/health` endpoint at all, which is a sidecar configuration issue, not an nginx/DNS one — re-check your sidecar's own setup instructions rather than repeating steps 1-5.

Once step 6 prints `ok`, type `https://watchshelf.example.com` into the Garmin watch app's server-address field — you're done.


> **Prefer not to add a new subdomain?** If you'd rather not create a whole new subdomain (for example your domain provider makes DNS changes annoying, or you just want everything under one domain), it's also possible to expose the sidecar as a path on a domain you're already serving, like `https://yourdomain.com/watchshelf/`, instead of a dedicated subdomain - that uses a different nginx `location` block and needs a couple of extra rewrite rules, so it's not covered step-by-step here, but know the option exists if the subdomain route above doesn't suit you.

---

## Apache

This guide is written for **Debian or Ubuntu Linux servers** (the kind of server most home ABS setups run on) — the commands `apt`, `a2enmod`, and `a2ensite` are specific to that family of Linux. If your server shows an error like `command not found` for any of these, you're probably on a different Linux distribution (e.g. CentOS, Fedora, or Rocky Linux, which use `dnf` instead of `apt` and don't have `a2enmod`/`a2ensite`) — say so and a version for your OS can be worked out separately.

Your sidecar is already running on your server at `127.0.0.1:8081`. Now you'll put a proper web address in front of it so the watch app can reach it. Do these steps in order — order matters.

### 1. Pick a subdomain and point it at your server

Decide on a subdomain, e.g. `watchshelf.example.com` (replace `example.com` with your own domain name — the one you already own/registered).

**Find your server's public IP address.** Run this on your server:
```
curl ifconfig.me
```
This prints a number like `203.0.113.42` — that's your server's public IP. Write it down.

**Add the DNS record.** Go to the website of whoever you registered your domain with (e.g. GoDaddy, Namecheap, Cloudflare, Google Domains). Log in, find your domain, and look for a section usually called **"DNS"** or **"DNS Management"** or **"DNS Settings"**. Add a new record:
- Type: **A** (or **AAAA** if the number `ifconfig.me` gave you has colons in it, like `2001:db8::1`)
- Name/Host: `watchshelf` (just the subdomain part, not the whole domain)
- Value/Points to: the IP address from `curl ifconfig.me` above

Save it.

**Check it's taken effect before moving on.** DNS changes can take anywhere from 2 minutes to a few hours to spread across the internet ("propagate"). Don't guess — check it. Run this on your server (or any computer):
```
nslookup watchshelf.example.com
```
- **Success**: you see your server's public IP address (the same number `curl ifconfig.me` gave you) in the output, under a line like `Address:`.
- **Not ready yet**: you see an error like `NXDOMAIN`, `can't find watchshelf.example.com`, or a different/no IP address at all. Wait 5–10 minutes and run the command again. Keep waiting and rechecking — do not move on to step 5 (getting the certificate) until this shows your correct IP, or that step will fail or hang confusingly.

### 2. Turn on the Apache features you need

Run:
```
sudo a2enmod proxy proxy_http ssl headers
sudo systemctl restart apache2
```
This turns on four Apache add-ons your setup needs: `proxy` and `proxy_http` (let Apache forward incoming requests to your sidecar program), `ssl` (lets Apache serve https, the padlock/secure version of a website), and `headers` (lets Apache add a small technical marker to forwarded requests that your sidecar needs, set up for you in step 4 — you don't need to understand it further).

**What success looks like:** the first command prints a few lines mentioning `Enabling module ssl` (and similar for the other modules) and ends with a line like `To activate the new configuration, you need to run: systemctl restart apache2` — that's expected, it's just a reminder, which is why the second command runs it for you. The second command (`systemctl restart apache2`) normally prints **nothing at all** if it works — no output is a good sign here, not a problem. If you instead see red text mentioning `failed` or `error`, something is wrong; stop and check that Apache is installed correctly before continuing.

### 3. Install certbot (gets your free https certificate)

This step also assumes Debian/Ubuntu. Run:
```
sudo apt install certbot python3-certbot-apache
```
Skip this if you already have certbot installed. (If you're on CentOS/Fedora/Rocky, the equivalent would use `dnf` instead of `apt` — ask if you need that version.)

### 4. Create the site config file

You'll create a small text file with a text editor called `nano`, which works right in your terminal. Run:
```
sudo nano /etc/apache2/sites-available/watchshelf.conf
```
This opens a blank editing screen in your terminal. Paste the block below into it exactly, replacing every `watchshelf.example.com` with the subdomain you set up in step 1:

```
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

    ProxyTimeout 1200
    TimeOut      1200

    ProxyPreserveHost On
    ProxyRequests Off

    ProxyPass        / http://127.0.0.1:8081/ flushpackets=on disablereuse=on timeout=1200
    ProxyPassReverse / http://127.0.0.1:8081/

    RequestHeader set X-Forwarded-Proto "https"
</VirtualHost>
```

Then save and exit: press **Ctrl+O** (that's the letter O, meaning "write Out"), then **Enter** to confirm the filename, then **Ctrl+X** to exit back to your normal terminal.

Quick note on what's in that block, so nothing looks mysterious: the `ProxyTimeout`/`TimeOut` lines make sure a long audiobook download doesn't get cut off partway — just leave them as-is. Everything else in the block (`ProxyPreserveHost`, `ProxyRequests`, `flushpackets`, `disablereuse`, `RequestHeader`) is standard plumbing that makes the forwarding work correctly and reliably — you don't need to understand each one, just paste it as shown and it's correct.

You won't have the certificate files (`fullchain.pem`/`privkey.pem`) yet — that's normal, the next step creates them. This config just needs to exist first so Apache is ready.

### 5. Turn on the site and get your certificate

Run these commands in this exact order:
```
sudo a2ensite watchshelf
sudo certbot --apache -d watchshelf.example.com
```
**What success looks like for the first command:** it prints a line like `Enabling site watchshelf.` followed by the same reminder as step 2 (`To activate the new configuration, you need to run: systemctl restart apache2`) — that's fine, you'll reload Apache properly in step 6, so no need to act on that reminder yet. No red `error`/`failed` text means it worked.

Certbot will ask for an email and to agree to terms — follow its prompts. It automatically fills in the certificate lines in your config file.

**If certbot fails or hangs here** (e.g. it times out, says it can't connect, or reports a "challenge failed" error): this almost always means the DNS check from step 1 wasn't actually ready. Go back and re-run `nslookup watchshelf.example.com` — if it doesn't show your server's IP, wait longer and try certbot again once it does.

### 6. Check the config and reload Apache

```
sudo apache2ctl configtest
sudo systemctl reload apache2
```
`configtest` should print `Syntax OK`. If it doesn't, re-check step 4 for typos (re-open the file with `sudo nano /etc/apache2/sites-available/watchshelf.conf` to fix it), then re-run both commands. The `reload` command normally prints nothing on success, same as in step 2.

### 7. Verify it worked

Run:
```
curl https://watchshelf.example.com/health
```
- **Success**: it prints exactly `ok`
- **Failure**: anything else (an error, a timeout, HTML, or nothing). Work through these in order:
  1. Re-check DNS: run `nslookup watchshelf.example.com` again — if it's not showing your server's IP, that's the problem, wait and retry.
  2. Check the sidecar itself is actually running, separately from Apache, by running this directly on your server: `curl 127.0.0.1:8081/health` — if that also fails, the problem is the sidecar/Docker container, not Apache or this guide (the sidecar needs to be running before this guide's steps can work).
  3. If both of those look fine but the https address still fails, re-check step 4's config file for typos and re-run step 6.

Once you see `ok`, type `https://watchshelf.example.com` into your watch app's server address field — you're done.


> **Prefer not to add a new subdomain?** If you'd rather not create a whole new subdomain (e.g. your DNS setup makes that a hassle, or you want the sidecar to live under a domain you already use for something else), Apache can also expose it as a path on an existing domain instead, like `example.com/watchshelf/`, using the same proxy idea but with a path-based `ProxyPass` block added to your existing site's config rather than a new `<VirtualHost>`. That variant isn't covered step-by-step here since it touches your existing site config and needs a couple of path-rewriting tweaks to work correctly — ask if you want that walkthrough instead.

---

## Caddy

Your sidecar is already running on your server at `127.0.0.1:8081` (that `8081` is the "port" - think of it like an apartment number that tells your server which program to talk to; you don't need to know more than that). Right now only your server itself can reach it. You need to put it "behind" a **reverse proxy** - a small always-on program that sits in front of your sidecar, takes requests from the internet at a real web address, and quietly forwards them to `127.0.0.1:8081`. We'll use a reverse proxy called Caddy, which is the easiest one to set up because it fetches its own HTTPS certificate (the thing that makes the address start with `https://` and show as secure) automatically - no extra steps needed.

**Before you start:** you need a domain name (or a free subdomain of one you already own), and a way to open a terminal on the server your sidecar is running on (for example by SSH-ing into it - if you set up the sidecar following an earlier step, use that same terminal/connection). If you don't have Caddy installed yet, install it now (instructions for your OS: https://caddyserver.com/docs/install).

1. **Pick a subdomain** for this - something like `watchshelf.example.com`, where `example.com` is a domain you own. Every example below uses `watchshelf.example.com` - swap in your real subdomain everywhere you see it.

2. **Point your subdomain at your server.** Log into wherever you manage your domain's DNS (e.g. your domain registrar, Cloudflare, etc.) and add an "A record" - a rule that says "when someone looks up `watchshelf.example.com`, send them to my server." Set:
   - Name/Host: `watchshelf` (or the full subdomain, depending on your provider's form)
   - Value/Points to: your server's public IP address (the IP address of the machine your sidecar is running on - if you don't know it, open a terminal **on that server** and run `curl ifconfig.me` to see it)

   This must be done first - Caddy needs it to prove to certificate authorities that you own the domain. (If your hosting provider gave you an IPv6 address too and you want to use that as well, add an "AAAA record" the same way - but the A record above is enough for most people, so skip this if you're not sure what it means.)

3. **Wait a few minutes** for the DNS change to take effect, then check it worked. In a terminal **on your own computer** (not the server), run:
   ```
   dig +short watchshelf.example.com
   ```
   This should print your server's IP address. If it prints nothing, wait a bit longer and try again. If you get an error like "command not found" (common on Windows, and on Macs that don't have developer tools installed), skip this check and just continue to the next step - you'll still catch any DNS problem in the final verify step.

4. **Open (or create) the Caddy config file.** In your terminal **on the server**, run:
   ```
   sudo nano /etc/caddy/Caddyfile
   ```
   `sudo` means "do this as an administrator" - it may ask for your password, which is normal, just type it (it won't show on screen) and press Enter. `nano` is a simple text editor that opens inside the terminal - you can type and move around with arrow keys like any text box.

5. **Paste this in.** If the file was empty, this is the whole file. If it already has other stuff in it, just add this to the end. Remember to replace `watchshelf.example.com` with your real subdomain:
   ```
   watchshelf.example.com {
       reverse_proxy 127.0.0.1:8081 {
           flush_interval -1
       }
   }
   ```
   (The `flush_interval -1` line makes sure book downloads stream smoothly instead of arriving all at once at the end - just leave it exactly as shown.)

6. **Save and close the file** (in nano: Ctrl+O, Enter, then Ctrl+X).

7. **Tell Caddy to reload** so it picks up the change and automatically fetches an HTTPS certificate for your subdomain. In your terminal on the server, run:
   ```
   sudo systemctl reload caddy
   ```
   This works for almost everyone - Caddy is usually installed to run automatically in the background this way. If, and only if, that command prints an error containing the words "unit not found," it means Caddy isn't set up to run that way on your system - in that case, run this instead:
   ```
   caddy reload --config /etc/caddy/Caddyfile
   ```

8. **Verify it worked.** Run this exact command (with your real subdomain), either on the server or on your own computer:
   ```
   curl https://watchshelf.example.com/health
   ```
   - **Success**: it prints exactly `ok`
   - **Failure**: any error, a blank response, or anything other than `ok`. Work through these in order:
     1. Check Caddy's own status for a clear error message: `sudo systemctl status caddy` (or, for more detail, `sudo journalctl -u caddy --no-pager -n 50`). This will often tell you directly what's wrong, e.g. a typo in the config file from step 5.
     2. Double-check step 2 (DNS) has fully taken effect and step 5's domain name was typed correctly (no leftover `example.com` placeholder).
     3. Make sure nothing on your server or network is blocking incoming connections on ports 80 and 443 (the "doors" Caddy needs open to the internet to fetch its certificate) - check your server/firewall/cloud provider's settings if you're unsure.
     4. Once you've fixed something, repeat step 7 to reload Caddy, then try step 8 again. Avoid repeating steps 7-8 many times in a row without changing anything in between - Caddy's certificate provider has a limit on how many times per hour/day it will issue a certificate for the same domain, so blind retries can temporarily lock you out.

You're done - `https://watchshelf.example.com` is the address to type into the watch app.


> **Prefer not to add a new subdomain?** If you'd rather not create a whole new subdomain, Caddy can also expose the sidecar as a path on a domain you're already serving, like `https://yourdomain.com/watchshelf/`, using a `handle_path` block inside your existing site instead of a brand new one - not covered step-by-step here, but know the option exists if the subdomain route above doesn't suit you.

---

## Traefik

Your sidecar is already running on your server. Right now it only answers at `127.0.0.1:8081`, which is a special address that only means "this same computer" - so only your server itself can talk to it, and your Garmin watch can't reach it over the internet. These steps give the sidecar a real web address (like `https://watchshelf.yourdomain.com`) that your watch can use instead.

**Before you start**, this guide assumes two things are already true for your setup:
- You already have a domain name you own (e.g. `yourdomain.com`), and you already point some part of it at your server to reach ABS over HTTPS.
- You're using **Traefik** as a "reverse proxy" in front of ABS. A reverse proxy is a small program that sits in front of your other programs and forwards incoming web requests to the right one - it's also what gets you the padlock/HTTPS on your ABS address instead of a plain unencrypted one.

If you're not sure whether you have Traefik, run this on your server:
```
docker ps | grep -i traefik
```
If you see a line of output mentioning `traefik`, you're good - continue below. If you see nothing, you're exposing ABS a different way (e.g. Cloudflare Tunnel, ngrok, or a raw IP/port), and this specific guide won't apply to you - stop here and ask for the guide matching your setup instead.

1. **Pick a subdomain for the sidecar.** A subdomain is just a new address that's part of a domain you already own - for example if you own `yourdomain.com`, then `watchshelf.yourdomain.com` is a subdomain of it. You don't need to buy anything new. Pick something like `watchshelf.yourdomain.com` (replace `yourdomain.com` with the domain you actually own).

2. **Point that subdomain at your server.** Go to wherever you manage your domain's DNS (e.g. Cloudflare, Namecheap, GoDaddy - DNS is the system that translates a name like `watchshelf.yourdomain.com` into the numeric address of your server). Add a record of type "A" (or "AAAA" if your server only has an IPv6 address) - an A/AAAA record is simply the instruction "when someone looks up this name, send them to this IP address":
   - Name/Host: `watchshelf` (or whatever subdomain you picked)
   - Value: the same IP address your existing ABS domain already points to (if you don't know it, look up the DNS record your ABS subdomain currently uses in this same dashboard, and copy its "Value"/"Content" field)
   - This can take a few minutes to a few hours to take effect.

3. **Find and open your `docker-compose.yml` file.** This is the same file that already runs your sidecar and Traefik - you (or whoever set this up) created it when you first installed ABS/the sidecar. To find it on your server:
   ```
   find / -name "docker-compose.yml" 2>/dev/null
   ```
   This lists every `docker-compose.yml` file on the server. Look for the one in the folder where you run your `docker compose` commands from (often something like `/home/youruser/abs/docker-compose.yml` or similar). Open it in any text editor, for example:
   ```
   nano /path/to/your/docker-compose.yml
   ```
   (replace `/path/to/your/` with the actual path you found)

4. **Find your existing ABS service's labels** in that file, and note down its "certresolver" name. A certresolver is just the name Traefik gives to "the settings it uses to automatically get an HTTPS certificate" - you're not creating anything new, just reusing the name Traefik already trusts. Look for a block in the file that looks like this (this is a real example, yours may have different service name/domain but the shape will match):
   ```yaml
     audiobookshelf:
       image: ghcr.io/advplyr/audiobookshelf
       # ...other existing settings...
       labels:
         - "traefik.enable=true"
         - "traefik.http.routers.abs.rule=Host(`abs.yourdomain.com`)"
         - "traefik.http.routers.abs.entrypoints=websecure"
         - "traefik.http.routers.abs.tls.certresolver=le"
   ```
   In this example, the certresolver name is `le` (the part after `certresolver=`, without the quotes). Write down whatever value appears after `certresolver=` in your own file - you'll paste that exact value in step 5.

5. **Find the sidecar's service block** in the same file - this is the block that starts the container listening on port 8081 (it might be named `watchshelf-sidecar`, or something else you or the installer chose - whatever it's currently called, leave that name as-is; you're only adding lines underneath it, not renaming it).

   Add a `labels:` block to it. The `labels:` line and everything under it must line up with (be indented exactly as far as) the other settings already inside that same block, like `image:` or `ports:`. Here's what it looks like before and after, so you can see exactly where the new lines go:

   Before (your existing block - name and contents may differ slightly):
   ```yaml
     watchshelf-sidecar:
       image: yourimage/watchshelf-sidecar
       restart: unless-stopped
   ```

   After (with the new `labels:` block added underneath, indented to match `image:` and `restart:` above it):
   ```yaml
     watchshelf-sidecar:
       image: yourimage/watchshelf-sidecar
       restart: unless-stopped
       labels:
         - "traefik.enable=true"
         - "traefik.http.routers.watchshelf.rule=Host(`watchshelf.yourdomain.com`)"
         - "traefik.http.routers.watchshelf.entrypoints=websecure"
         - "traefik.http.routers.watchshelf.tls.certresolver=le"
         - "traefik.http.services.watchshelf.loadbalancer.server.port=8081"
         - "traefik.http.services.watchshelf.loadbalancer.responseforwarding.flushinterval=1ms"
   ```

   Replace `watchshelf.yourdomain.com` with your real subdomain from step 1, and replace `le` with the certresolver name you wrote down in step 4 (only if it's different from `le` - many setups do use `le`).

   What each new line means, in plain English:
   - `entrypoints=websecure` - tells Traefik "serve this over HTTPS," the same way it already does for ABS.
   - `loadbalancer.server.port=8081` - tells Traefik which internal port to send traffic to. This is NOT a port you open to the internet; it's just how Traefik finds the sidecar over Docker's internal network, a private network that only lets containers on your server talk to each other, invisible from outside.
   - `responseforwarding.flushinterval=1ms` (last line) - makes audiobook downloads stream smoothly to your watch instead of arriving all at once at the end. Just copy it as-is, no changes needed.

   Important: do NOT add a `ports: - "8081:8081"` line for the sidecar. Traefik reaches it directly over Docker's internal network using the name and port in the labels above - opening the port on the host isn't needed and is a security risk.

   Before moving on, double check: the `labels:` line and the six `-` lines under it all use spaces (not tabs) and line up under the sidecar block, matching the indentation of `image:`/`restart:` in that same block. Getting this indentation wrong is the single most common mistake in this step - if you're unsure, delete your edit and copy the "After" example above exactly, only changing the two values mentioned.

6. **Save the file**, then apply the change by running this in the same folder as `docker-compose.yml`:
   ```
   docker compose up -d
   ```
   - **Success looks like**: a few lines mentioning your sidecar's container name and the word `Started` or `Running`, with no red `Error` text.
   - **If you see an error mentioning "yaml" or "mapping" or "did not find expected"**: this means the indentation from step 5 is off. Reopen the file and re-check that every line under `labels:` lines up exactly as shown in the "After" example - re-copy it exactly if needed, then run `docker compose up -d` again.
   - **If you see an error mentioning "port is already allocated"**: you likely still have a `ports: - "8081:..."` line left over for the sidecar - remove it (see the important note in step 5) and run the command again.

7. **Wait about a minute** for Traefik to request the HTTPS certificate for your new subdomain, then verify it worked by running this exact command (replace `watchshelf.yourdomain.com` with the real subdomain you chose in step 1):
   ```
   curl https://watchshelf.yourdomain.com/health
   ```
   - **Success**: the command prints exactly `ok`
   - **Failure - `curl: (6) Could not resolve host`**: DNS from step 2 hasn't caught up yet - wait longer and retry.
   - **Failure - `curl: (35) SSL connect error`**: the certificate isn't ready yet - wait a minute and retry.
   - **Failure - connection refused or timeout**: double-check the labels in step 5 match your sidecar's actual service name and port, and that `docker compose up -d` in step 6 reported no errors.

Once you see `ok`, type `https://watchshelf.yourdomain.com` into your watch app's server address field - you're done.


> **Prefer not to add a new subdomain?** If you'd rather not create a new subdomain, Traefik can also route by URL path (e.g. `yourdomain.com/watchshelf`) off your existing ABS domain, using a `PathPrefix` rule and a `stripprefix` middleware instead of a `Host` rule - this avoids the DNS step above but adds a couple of extra labels, and only makes sense if you're out of subdomains or don't have DNS access. For most people the subdomain method above is simpler and is the standard, documented path.


---

## Step 3 — log into the watch

1. Open **WatchShelf** on the watch (under Music / audio providers).
2. Tap **Log in**.
3. Enter the **web address you just set up in Step 2** — not your Audiobookshelf
   address. For example `https://watchshelf.yourdomain.com`.
4. Enter your normal Audiobookshelf username and password.

That's it — **Browse library** should now show your books, with options to browse
by all books, author, series, or collection.

## Something not working?

- Re-check the exact `curl .../health` command from your proxy's section above — if
  that doesn't print `ok`, fix that first before touching the watch at all.
- Make sure you entered the **sidecar's** address on the watch, not Audiobookshelf's.
- If the watch shows a login error, double check your Audiobookshelf username and
  password work by logging into Audiobookshelf's own web page normally.

