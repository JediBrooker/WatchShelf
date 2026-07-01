# WatchShelf

A Garmin **Audio Content Provider** app that streams-then-plays audiobooks from a
self-hosted [Audiobookshelf](https://audiobookshelf.org) (ABS) server on a
**Garmin Tactix 8** and other music-capable Garmin watches. Download a book over
Wi-Fi/LTE, then play it offline with part/chapter navigation and two-way progress
sync back to ABS.

WatchShelf is a lean adaptation of Garmin's official **MonkeyMusic** sample: the
same class hierarchy and system hooks (proven to compile), with the music-server
logic swapped for Audiobookshelf + a tiny transcode sidecar.

> **Status:** compiles clean against **Connect IQ SDK 9.2.0** (`make build` →
> `bin/WatchShelf.prg` for the Tactix 8 / `fenix847mm`), CLI-only (see
> [BUILD.md](BUILD.md)). The ABS client + sidecar are **validated end-to-end
> against a live ABS server**: browse, direct MP3 download, m4b→ADTS convert, and
> progress write-back (ABS confirmed updated) all pass. What remains is on-watch
> playback itself (native player → Bluetooth), which needs the device/simulator.

---

## Architecture

```
  Garmin watch (WatchShelf, Monkey C)
    |  Application.Properties: ABS server URL, API key, sidecar URL, sidecar key
    |
    |-- browse:   GET  {abs}/api/libraries, /libraries/:id/items, /items/:id
    |-- download: GET  audio (one FILE = one track; or one chapter for 1-file books)
    |               mp3:     {abs}/api/items/:id/file/:ino/download   (direct, byte-exact)
    |               aac/m4b: {sidecar}/transcode?...&fmt=m4a          (lossless AAC->ADTS)
    |               flac/cut:{sidecar}/transcode?...&fmt=mp3[&start&end]
    |-- progress: POST {sidecar}/progress -> sidecar PATCHes {abs}/api/me/progress/:itemId
    v
  Transcode sidecar (node:http + ffmpeg, 127.0.0.1:8081, behind your proxy on :443)
    |  holds the ABS token server-side; watch authenticates with a shared key
    |-- GET {abs}/api/items/:id/file/:ino/download  (Bearer, server-side)
    |-- ffmpeg -> mp3 64k mono (or ADTS copy), streamed back to the watch
    v
  Audiobookshelf server
```

### The four provider flows (system-invoked, from `WatchShelfApp`)

| System hook | WatchShelf view/delegate | What it does |
|---|---|---|
| `getSyncConfigurationView()` | `LibraryView(MODE_SYNC)` -> `LibraryMenuDelegate` -> `BookMenuDelegate` | Browse ABS **library -> book**, queue its tracks (per file, or per chapter for single-file books), kick a sync |
| `getSyncDelegate()` | `SyncDelegate` | Background download each queued track as audio; delete queued items |
| `getPlaybackConfigurationView()` | `LibraryView(MODE_PLAYBACK)` -> `DownloadedMenu` | **Downloaded** management screen (cache size, tap to remove) |
| `getContentDelegate()` | `ContentDelegate` -> `ContentIterator` | Serve chapter tracks to the native player; sync progress on position change |

All app state (download queue, delete queue, downloaded-track map) lives in
`Application.Storage` as **ids only** - audio bytes live in the device media
cache (`Media.getCachedContentObj` / `deleteCachedItem` / `getCacheStatistics`).
User settings (server URL, API key, sidecar URL/key) live in
`Application.Properties`, editable from Garmin Connect Mobile / Express.

### Tracks: one per file, or one per chapter

Each **audio file** becomes a separate `Media` track, so Next/Previous move
part-to-part — this is what makes **multi-file books** (the common case in a real
library) work. For a **single-file book that has chapters**, WatchShelf instead
cuts one track per chapter via the sidecar (`start`/`end` -> ffmpeg `-ss`/`-t`)
for smaller downloads and real chapter navigation. Every track stores its
**book-absolute start offset** so progress maps back to ABS.

### Progress sync (two-way)

* **On load:** `userMediaProgress.currentTime` is read from item detail.
* **On play:** `ContentDelegate.onSong` fires on the notify/pause/stop/complete
  events; WatchShelf converts the in-track position to **book-absolute** seconds
  (`trackStart + position`) and POSTs it to the sidecar's `/progress`.

> **Why progress goes through the sidecar:** Garmin's `Communications` has **no**
> `HTTP_REQUEST_METHOD_PATCH` (only GET/POST/PUT/DELETE), ABS's endpoint is
> `PATCH /api/me/progress/:id`, and ABS **ignores** `X-HTTP-Method-Override`
> (verified live: POST → 404). So WatchShelf **POSTs to the sidecar's
> `/progress`**, which issues the real PATCH server-side. Tested end-to-end — ABS
> confirmed updated. (The watch's own ABS token isn't even needed for progress.)

---

## The gotchas (read these)

### 1. Audiobookshelf will not hand us a plain MP3 -> the sidecar exists

ABS's own transcoder emits **HLS/AAC**, which Garmin's `makeWebRequest` audio
downloader **cannot consume**. Garmin needs a single, self-contained file with
`:mediaEncoding` matching the body (`ENCODING_MP3` <-> `audio/mpeg`). So, by codec:

* **mp3 files** -> direct-download the byte-exact file from ABS (no sidecar).
* **aac / m4b / m4a files** -> **sidecar**, which copies the AAC stream to **ADTS**
  (lossless, no re-encode; Garmin plays it via `ENCODING_ADTS`).
* **flac / opus / ... and per-chapter cuts** -> **sidecar** transcode to **64 kbps
  mono MP3** (~28 MB/hour).

The sidecar has **ffmpeg pull the source from ABS over HTTP** (Range-seekable, so
`.m4b`/`.mp4` `moov`-at-end demuxing and chapter `-ss` seeks both work), and holds
the ABS token server-side. In a real library MP3 dominates (a live check found
70 mp3 vs 6 m4b, zero flac), so the sidecar mainly matters for a few m4b books,
per-chapter cuts, and progress.

### 2. On-device audio downloads require real HTTPS on :443 with a valid cert

Audio downloads are performed by the **watch directly**, not proxied through
Garmin's servers. In the simulator you can disable *Settings > Use Device HTTPS
Requirements*, but **on a real Tactix 8 the ABS/sidecar endpoints must be HTTPS
on port 443 with a complete, valid certificate chain** - a self-signed or
incomplete-chain cert makes `makeWebRequest` audio downloads fail on-device
(even when they work in the sim). Put both ABS and the sidecar behind a reverse
proxy that terminates TLS with a real cert (see `sidecar/Caddyfile.snippet`).

### 3. If ABS is behind Cloudflare, mind the User-Agent

A live test showed the reference server sits behind **Cloudflare**, which **403s
bot-like User-Agents** (the literal `Python-urllib` was blocked; a `Garmin`/empty
UA passed). The watch's own UA is very likely fine, but if the app ever gets a
403, allowlist the Garmin UA (or the `/api/*` paths) in Cloudflare. The
**sidecar** sends a normal UA on its ABS calls and is best pointed at ABS's
**internal** URL (e.g. `http://127.0.0.1:13378`) so it skips Cloudflare entirely.

---

## Setup

Build it with **`make build`** (see **[BUILD.md](BUILD.md)** - CLI only, no editor; verified against SDK 9.2.0). Then:

1. **ABS API key** - create a long-lived key (ABS Settings -> API Keys) for a
   user with **download** permission. Put it in the app's *Audiobookshelf API
   key* setting and in the sidecar's `ABS_TOKEN`.
2. **Sidecar** - `cd sidecar && cp .env.example .env` (fill in), then
   `npm start`. Requires `ffmpeg` on `PATH`. Mount it behind your proxy with the
   Caddy/nginx snippet.
3. **App settings** (Garmin Connect Mobile / Express) - set *Server URL*,
   *API key*, *Sidecar URL*, *Sidecar key*.

---

## Known limitations (first version)

* **Chaptered multi-file books:** a book that is *both* multi-file *and* has
  book-level chapters is played per **file** (not per chapter) — chapter cutting
  is only applied to single-file books. Per-file navigation still works.
* **Resume seek:** saved position is read and logged; the native player resumes
  at track boundaries. Sample-accurate mid-track resume is a future step.
* **No play sessions:** for offline playback WatchShelf skips ABS play sessions
  and syncs via the progress endpoint only (simpler, no session reaping).
