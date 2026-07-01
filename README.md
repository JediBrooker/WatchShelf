# WatchShelf

A Garmin **Audio Content Provider** app that streams-then-plays audiobooks from a
self-hosted [Audiobookshelf](https://audiobookshelf.org) (ABS) server on a
**Garmin Tactix 8** and other music-capable Garmin watches. Download a book's
chapters over Wi-Fi/LTE, then play them offline with real chapter navigation and
two-way progress sync back to ABS.

WatchShelf is a lean adaptation of Garmin's official **MonkeyMusic** sample: the
same class hierarchy and system hooks (proven to compile), with the music-server
logic swapped for Audiobookshelf + a tiny transcode sidecar.

> **Status:** compiles clean against **Connect IQ SDK 9.2.0** - `make build` →
> `bin/WatchShelf.prg` for the Tactix 8 (`fenix847mm`). Build is CLI-only (no
> editor); see [BUILD.md](BUILD.md). Runtime behaviours (audio download/playback,
> progress-sync PATCH) still to confirm on the simulator/device.

---

## Architecture

```
  Garmin watch (WatchShelf, Monkey C)
    |  Application.Properties: ABS server URL, API key, sidecar URL, sidecar key
    |
    |-- browse:   GET  {abs}/api/libraries, /libraries/:id/items, /items/:id
    |-- download: GET  audio (one CHAPTER = one Media track)
    |               direct:  {abs}/api/items/:id/file/:ino/download   (mp3/m4a books)
    |               sidecar: {sidecar}/transcode?...&start&end&fmt=mp3 (chapters / flac/opus)
    |-- progress: POST {abs}/api/me/progress/:itemId  (X-HTTP-Method-Override: PATCH)
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
| `getSyncConfigurationView()` | `LibraryView(MODE_SYNC)` -> `LibraryMenuDelegate` -> `BookMenuDelegate` | Browse ABS **library -> book**, queue every chapter, kick a sync |
| `getSyncDelegate()` | `SyncDelegate` | Background download each queued chapter as an audio track; delete queued items |
| `getPlaybackConfigurationView()` | `LibraryView(MODE_PLAYBACK)` -> `DownloadedMenu` | **Downloaded** management screen (cache size, tap to remove) |
| `getContentDelegate()` | `ContentDelegate` -> `ContentIterator` | Serve chapter tracks to the native player; sync progress on position change |

All app state (download queue, delete queue, downloaded-track map) lives in
`Application.Storage` as **ids only** - audio bytes live in the device media
cache (`Media.getCachedContentObj` / `deleteCachedItem` / `getCacheStatistics`).
User settings (server URL, API key, sidecar URL/key) live in
`Application.Properties`, editable from Garmin Connect Mobile / Express.

### Chapters as tracks

Each **chapter** is downloaded as a **separate `Media` track** (never flattened)
so the watch's Next/Previous buttons move chapter-to-chapter. Because ABS only
serves whole files, per-chapter slices are cut by the sidecar (`start`/`end` ->
ffmpeg `-ss`/`-to`) into small, complete mp3s.

### Progress sync (two-way)

* **On load:** `userMediaProgress.currentTime` is read from item detail.
* **On play:** `ContentDelegate.onSong` fires on the notify/pause/stop/complete
  events; WatchShelf converts the in-chapter position to **book-absolute**
  seconds (`chapterStart + position`) and updates `/api/me/progress/:itemId`.

> **Note on PATCH:** Garmin's `Communications` module has **no**
> `HTTP_REQUEST_METHOD_PATCH` (only GET/PUT/POST/DELETE). ABS's progress
> endpoint is `PATCH /api/me/progress/:id`, so WatchShelf issues a **POST** with
> an `X-HTTP-Method-Override: PATCH` header. ABS (an Express app) honours this
> when method-override is enabled. If your ABS build does not, enable
> method-override at the reverse proxy, or extend the sidecar with a
> `POST /progress` route that forwards a real PATCH server-side.

---

## The two gotchas (read these)

### 1. Audiobookshelf will not hand us a plain MP3 -> the sidecar exists

ABS's own transcoder emits **HLS/AAC**, which Garmin's `makeWebRequest` audio
downloader **cannot consume**. Garmin needs a single, self-contained file with
`:mediaEncoding` matching the body (`ENCODING_MP3` <-> `audio/mpeg`). So:

* **mp3 / m4a / m4b books** -> direct-download the byte-exact file from ABS.
* **flac / opus / ogg / wma books, and all per-chapter cuts** -> route through the
  **sidecar**. It has **ffmpeg pull the source from ABS over HTTP** (Range-seekable,
  so `.m4b`/`.mp4` `moov`-at-end demuxing and chapter `-ss` seeks both work), then
  returns **64 kbps mono MP3** (spoken-word sweet spot, ~28 MB/hour) or, for AAC
  sources, a lossless **AAC -> ADTS copy** (no re-encode).

The sidecar holds the ABS token server-side; the watch never sees it and
authenticates to the sidecar with its own shared key.

### 2. On-device audio downloads require real HTTPS on :443 with a valid cert

Audio downloads are performed by the **watch directly**, not proxied through
Garmin's servers. In the simulator you can disable *Settings > Use Device HTTPS
Requirements*, but **on a real Tactix 8 the ABS/sidecar endpoints must be HTTPS
on port 443 with a complete, valid certificate chain** - a self-signed or
incomplete-chain cert makes `makeWebRequest` audio downloads fail on-device
(even when they work in the sim). Put both ABS and the sidecar behind a reverse
proxy that terminates TLS with a real cert (see `sidecar/Caddyfile.snippet`).

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

* **Multi-file books:** chapters are cut from the **first** audio file's `ino`.
  Books split across multiple files (where chapters span files) are not yet
  mapped file-by-file. Single-file `.m4b`/`.mp3` books (the common case) work.
* **Resume seek:** saved position is read and logged; the native player resumes
  at chapter boundaries. Sample-accurate mid-chapter resume is a future step.
* **No play sessions:** for offline playback WatchShelf skips ABS play sessions
  and syncs via the progress endpoint only (simpler, no session reaping).
