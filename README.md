# WatchShelf

A Garmin **Audio Content Provider** app that downloads and plays audiobooks from a
self-hosted [Audiobookshelf](https://audiobookshelf.org) (ABS) server on a **Garmin
Tactix 8** (and other music-capable Garmin watches). Log in on the watch, browse your
whole library, download a book, and listen offline — with two-way progress sync.

> **Status (build `b10`):** compiles clean for the Tactix 8 Solar (`fenix8solar51mm`,
> SDK 9.2). On-watch login, browsing all books, per-chunk downloads, and progress
> write-back are **validated end-to-end against a live ABS server**. The one thing
> only real hardware can confirm is the native player actually playing a downloaded
> chunk over Bluetooth.

## The sidecar is required (here's why)

A real ABS library is mostly **single files of 200 MB – 1 GB** (a 25-hour book is one
1 GB file). A watch can't download a file that big in one request, and it can't accept
an "item detail" response large enough to even *list* a many-file book. So WatchShelf
routes everything through a tiny **Node + ffmpeg sidecar** behind your ABS domain at
`/watchshelf-transcode`:

- `/list`, `/files` → lean JSON (a few KB) so listings never overflow the watch.
- `/transcode` → cuts a small on-demand mp3 chunk out of any file via HTTP Range
  (never downloads the whole gigabyte).
- `/progress` → forwards progress as a real `PATCH` to ABS (Monkey C has no PATCH).

It auths with the watch's own ABS token, so there's nothing extra to configure.
**Deploy it in ~2 minutes:** [sidecar/README.md](sidecar/README.md).

## How it works

```
 Watch (WatchShelf, Monkey C)
  |  on-watch login: server URL + username + password -> ABS token (stored; pw discarded)
  |
  |-- browse:   GET  {server}/watchshelf-transcode/{list|authors|series|collections} -> lean lists
  |-- open:     GET  {server}/watchshelf-transcode/files?item    -> the book's files (lean)
  |-- queue:    split each file into 30-min chunks
  |-- sync:     GET  {server}/watchshelf-transcode/transcode?item&file&start&end -> mp3 chunk
  |-- play:     native media player -> Bluetooth
  |-- progress: POST {server}/watchshelf-transcode/progress      -> sidecar PATCHes ABS
  v
 Sidecar (Node + ffmpeg)  ->  Audiobookshelf
```

- **Login is on the watch** (`TextPicker`), because a sideloaded app can't use Garmin
  Connect phone settings. Only the token is stored, never the password.
- **Everything heavy routes through the sidecar** (chunked downloads + lean lists).
- **Chunks** are 30-min, 64 kbps mono mp3 (~14 MB). Tune in `source/BookMenuDelegate.mc`.
- **State** lives in `Application.Storage` as chunk *params* (not URLs) to stay small.
- Auth to ABS is a **Bearer/`?token=`** JWT from `POST /login`.

## Build & run

CLI only, no editor — see [BUILD.md](BUILD.md).

```
make build            # -> bin/WatchShelf.prg for the Tactix 8 Solar (fenix8solar51mm)
```

Sideload `bin/WatchShelf.prg` to the watch's `GARMIN/APPS/` (the tactix 8 is MTP on
macOS — use OpenMTP or Android File Transfer; power-cycle the watch if a client can't
see it). WatchShelf appears under the watch's **Music / audio providers**. Open it →
**Log in** → **Browse library** → **All books / By author / By series / By
collection** → pick a book → it downloads in chunks.

## Known limitations

- **Long books = many chunks** (a 25-hour book → ~50). Sync is slow but works; each
  chunk is a small independent download.
- **On-device playback** of a chunk (native player → Bluetooth) is the one path not yet
  confirmed on hardware.
- **No phone/Garmin-Connect settings** (sideloaded apps can't). All config is on-watch;
  publishing to the Connect IQ Store would enable phone settings later.
