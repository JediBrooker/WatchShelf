# WatchShelf

A Garmin **Audio Content Provider** app that downloads and plays audiobooks from a
self-hosted [Audiobookshelf](https://audiobookshelf.org) (ABS) server on a **Garmin
Tactix 8** (and other music-capable Garmin watches). Log in on the watch, browse your
whole library, download a book, and listen offline — with two-way progress sync.

> **Status (build `b12`):** compiles clean for the Tactix 8 Solar (`fenix8solar51mm`,
> SDK 9.2). On-watch login, browsing (all books / author / series / collection),
> per-chunk downloads, and progress write-back are **validated end-to-end against a
> live ABS server**. The one thing only real hardware can confirm is the native player
> actually playing a downloaded chunk over Bluetooth.

## Architecture — the watch talks only to the sidecar

A real ABS library is mostly **single files of 200 MB – 1 GB** (a 25-hour book is one
1 GB file). A watch can't download a file that big in one request, and it can't accept
an "item detail" response large enough to even *list* a many-file book. So WatchShelf
puts a tiny **Node + ffmpeg sidecar** in front of ABS, and the watch talks to **only
the sidecar**:

- lean lists (`/libraries`, `/list`, `/authors`, `/series`, `/collections`, `/files`)
  so nothing overflows the watch;
- `/transcode` cuts a small on-demand AAC/M4A chunk out of any file via HTTP Range
  (it never downloads the whole gigabyte), with a real container so the native
  player shows a position/time indicator;
- `/cover` serves the book's cover for menu thumbnails and player album art;
- `/login` + `/progress` proxy to ABS, so **Audiobookshelf itself never has to be
  exposed to the internet** — it can stay fully private.

You expose the **sidecar** at any HTTPS URL and enter *that* URL on the watch. One
command installs the sidecar and walks you through exposing it:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/JediBrooker/WatchShelf/main/sidecar/install.sh)"
```

Or do it by hand — a plain, step-by-step guide (including *why* the sidecar is
needed at all) for each of **Cloudflare Tunnel, nginx, Apache, Caddy, and
Traefik** is in [sidecar/GETTING_STARTED.md](sidecar/GETTING_STARTED.md).

## How it works

```
 Watch (WatchShelf, Monkey C)
  |  on-watch login: SIDECAR URL + username + password
  |
  |-- login:    POST {sidecar}/login        -> ABS token (stored; password discarded)
  |-- browse:   GET  {sidecar}/{libraries|list|authors|series|collections} -> lean lists
  |-- open:     GET  {sidecar}/files?item    -> the book's files (lean)
  |-- queue:    split each file into ~3-min chunks
  |-- sync:     GET  {sidecar}/transcode?item&file&start&end -> M4A chunk
  |             GET  {sidecar}/cover?item                    -> cover art
  |-- play:     native media player -> Bluetooth
  |-- progress: POST {sidecar}/progress      -> sidecar PATCHes ABS
  v
 Sidecar (Node + ffmpeg)  ->  Audiobookshelf (internal)
```

- **The watch only ever talks to the sidecar.** ABS can stay on a private network.
- **Login is on the watch** (`TextPicker`), because a sideloaded app can't use Garmin
  Connect phone settings. Only the ABS token is stored, never the password.
- **Chunks** are ~3-min, 96 kbps mono AAC in a real M4A container (~2 MB) — the
  container is what lets the native player show a position/time indicator. Tune in
  `source/Chunks.mc`.
- **State** lives in `Application.Storage` as chunk *params* (not URLs) to stay small.

## Build & run

CLI only, no editor — see [BUILD.md](BUILD.md).

```
make build            # -> bin/WatchShelf.prg for the Tactix 8 Solar (fenix8solar51mm)
```

Sideload `bin/WatchShelf.prg` to the watch's `GARMIN/APPS/` (the tactix 8 is MTP on
macOS — use OpenMTP or Android File Transfer; power-cycle the watch if a client can't
see it). WatchShelf appears under the watch's **Music / audio providers**. Open it →
**Log in** (enter your **sidecar** URL, then your ABS username + password) → **Browse
library** → **All books / By author / By series / By collection** → pick a book → it
downloads in chunks.

## Known limitations

- **Long books = many chunks** (a 25-hour book → ~50). Sync is slow but works; each
  chunk is a small independent download.
- **On-device playback** of a chunk (native player → Bluetooth) is the one path not yet
  confirmed on hardware.
- **No phone/Garmin-Connect settings** (sideloaded apps can't). All config is on-watch;
  publishing to the Connect IQ Store would enable phone settings later.
