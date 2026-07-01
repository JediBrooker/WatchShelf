# WatchShelf sidecar

Your Audiobookshelf library is mostly **single files of 200 MB – 1 GB** (a 25-hour
audiobook is one 1 GB file). A Garmin watch cannot download a file that big in one
request, and it can't accept an ABS "item detail" response big enough to *list* a
many-file book. So this tiny Node + ffmpeg service:

- **`/list`, `/files`** — return lean JSON (a few KB) so book/file lists never
  overflow the watch.
- **`/transcode`** — cuts a small on-demand mp3 chunk out of any file using an HTTP
  Range request (it never downloads the whole gigabyte — a 30-min chunk is ~14 MB).
- **`/progress`** — forwards the watch's progress as a real `PATCH` to ABS (Monkey C
  has no PATCH method).

It auths with the **watch's own ABS token** (passed per-request), so there is no
separate secret to configure. The only required setting is `ABS_URL`.

## Deploy (Docker, ~2 min)

1. In `docker-compose.yml`, set `ABS_URL` to your ABS address — prefer the internal
   one (e.g. `http://audiobookshelf:13378`) to bypass Cloudflare; the public https
   URL also works (the sidecar sends a browser-like User-Agent).
2. `docker compose up -d --build`
3. Add a `/watchshelf-transcode/*` route to whatever fronts your ABS domain (the
   thing Cloudflare points at) — see `Caddyfile.snippet` (Caddy / nginx / Cloudflare
   Tunnel). It must **strip** the prefix.
4. Verify: `curl https://books.jedibrooker.com/watchshelf-transcode/health` → `ok`.

That's it — open WatchShelf on the watch, browse, and download a book.

## Or bare Node

`ABS_URL=http://127.0.0.1:13378 node server.js` (needs Node 18+ and `ffmpeg` on
PATH), then add the same reverse-proxy route.

## Tuning

- **Chunk length** is 30 min, set in the watch app (`source/BookMenuDelegate.mc`,
  `chunk = 1800`). Smaller → more, smaller downloads; larger → fewer, bigger.
- **Quality** is 64 kbps mono mp3 (spoken-word sweet spot). Change in `server.js`
  `ffArgs`.
