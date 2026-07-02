# WatchShelf sidecar

Your Audiobookshelf library is mostly **single files of 200 MB – 1 GB** (a 25-hour
audiobook is one 1 GB file). A Garmin watch cannot download a file that big in one
request, and it can't accept an ABS "item detail" response big enough to *list* a
many-file book. So this tiny Node + ffmpeg service sits in front of ABS, and **the
watch talks to only the sidecar** — ABS itself never has to be exposed to the
internet:

- **`/login`** — proxies to ABS `/login`, returns just `{user:{token}}`.
- **`/libraries`, `/list`, `/authors`, `/series`, `/collections`, `/files`** — lean
  JSON (a few KB) so listings never overflow the watch.
- **`/transcode`** — cuts a small on-demand mp3 chunk out of any file using an HTTP
  Range request (it never downloads the whole gigabyte — a 30-min chunk is ~14 MB).
- **`/progress`** — forwards the watch's progress as a real `PATCH` to ABS (Monkey C
  has no PATCH method).

It auths with the **watch's own ABS token** (obtained via `/login`, then passed
per-request), so there is no separate secret to configure. The only required setting
is `ABS_URL` — Audiobookshelf's address *as seen from this container/host* (an
internal address is fine and preferred, since the sidecar is now the only thing that
needs to be public).

## Deploy (Docker, ~2 min)

1. In `docker-compose.yml`, set `ABS_URL` to ABS's address as seen from this
   container (`http://host.docker.internal:13378` if ABS runs on the host, or the
   compose service name if it's a sibling container — see the comments in the file).
2. `docker compose up -d --build`
3. Expose the sidecar over HTTPS with **whatever reverse proxy you already run** —
   see [PROXIES.md](PROXIES.md) for copy-pasteable recipes (Cloudflare Tunnel, nginx,
   Apache, Caddy, Traefik). The simplest and recommended shape is a **dedicated
   subdomain** (e.g. `watchshelf.example.com`) pointed straight at the sidecar; a
   same-domain path (`books.example.com/watchshelf-transcode`) also works if you'd
   rather not add a subdomain.
4. Verify: `curl https://<whatever you exposed>/health` → `ok`.
5. On the watch, log in with that URL — **not** your ABS server's URL.

That's it — browse and download a book.

## Or bare Node

`ABS_URL=http://127.0.0.1:13378 node server.js` (needs Node 18+ and `ffmpeg` on
PATH), then expose it the same way (step 3 above).

## Tuning

- **Chunk length** is 30 min, set in the watch app (`source/BookMenuDelegate.mc`,
  `chunk = 1800`). Smaller → more, smaller downloads; larger → fewer, bigger.
- **Quality** is 64 kbps mono mp3 (spoken-word sweet spot). Change in `server.js`
  `ffArgs`.
