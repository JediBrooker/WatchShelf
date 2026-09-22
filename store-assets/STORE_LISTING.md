# Connect IQ store listing — b39

Copy blocks below straight into the store fields. Keep this file updated with
the listing so the two never drift.

---

## App name

```
WatchShelf
```

## Short description

```
Listen to your own Audiobookshelf library on your watch — offline, with two-way progress sync.
```

---

## Description

```
WatchShelf plays audiobooks and podcasts from YOUR OWN self-hosted
Audiobookshelf server, downloaded onto the watch so you can listen with
Bluetooth headphones and no phone.

REQUIRES A SELF-HOSTED SETUP
This app is not a store or a streaming service. You need:
  1. An Audiobookshelf server (audiobookshelf.org) with your own library.
  2. The free WatchShelf sidecar running next to it, reachable over HTTPS.
Without both, the app has nothing to play. Setup guide:
github.com/JediBrooker/WatchShelf

WHY A SIDECAR?
Audiobooks are often single files of 200 MB - 1 GB. A watch cannot download a
file that size, or even accept a list of a many-file book. The sidecar cuts
small on-demand chunks and serves lean listings, so Audiobookshelf itself never
has to be exposed to the internet — only the sidecar does.

WHAT YOU CAN DO
  - Browse your whole library: all books, by author, by series, by collection
  - Continue Listening picks up what you started on any device
  - Download only the part you have not heard yet
  - Choose playback speed per book - 1.0x, 1.25x, 1.5x, 1.75x or 2.0x - from
    the book's own menu, after it is already on your watch
  - Podcast libraries work too — each show browses like an author, each
    episode like a book
  - Chapter skip, 30-second jumps, and whole-book progress on the player
  - Two-way progress sync: finish a chapter on the watch, carry on in the car
  - Log in on the watch; only a token is stored, never your password
  - Optional shared-secret header so a reverse proxy can lock the sidecar to
    your watch alone

GOOD TO KNOW
  - Downloads take a while. A long book is many small chunks by design — that
    is what keeps it within a watch's memory.
  - Podcast episodes must already be downloaded in Audiobookshelf.
  - The player's time bar covers the current part; whole-book percentage is
    shown on the artist line.

Open source, MIT licensed: github.com/JediBrooker/WatchShelf
```

---

## What's New — b39

> **The backend announcement is the first line on purpose.** Anyone updating
> the app without updating the sidecar loses all downloads, so it must not be
> buried under the feature list.

```
UPDATE YOUR SIDECAR FIRST

This release needs a newer WatchShelf sidecar. If you update the watch app
without updating the sidecar, downloads will fail until you do.

  docker compose pull && docker compose up -d

Or use the prebuilt image, new in this release:
  ghcr.io/jedibrooker/watchshelf:latest   (amd64 and arm64)

NEW
  - Set up from your phone. Garmin Connect > WatchShelf > Settings takes your
    WatchShelf URL and an Audiobookshelf API key, and the watch then needs no
    typing at all. The app now offers this when you first open it, instead of
    sending you straight to the on-watch keyboard.
  - Playback speed per book: 1.0x, 1.25x, 1.5x, 1.75x, 2.0x. Choose it from a
    downloaded book's menu, next to Resume and Play from start - not only when
    you download it.

    A watch cannot change the speed of audio it is holding, so a speed you have
    not used before has to be fetched. WatchShelf keeps the previous one when
    there is room, so switching BACK to a speed you already have is instant.
    The menu shows which speeds are on the watch.
  - Podcast libraries: each show browses like an author, each episode like a
    book, with per-episode progress sync.
  - Optional shared-secret header, so a reverse proxy can reject anything that
    is not your watch.
  - Prebuilt sidecar Docker images for amd64 and arm64 (Raspberry Pi, ARM NAS).

FIXED
  - Long books could hang or fail to play on the watch. Building the playlist
    was too slow on books with several hundred parts and the watchdog killed
    playback. Thanks to @Ayfteyd7Od and @idanbauer for finding and fixing it.
  - Login crashed on vivoactive 4 / 4s and Venu / Venu D, which have no
    on-screen keyboard. Those watches now get an on-watch character wheel.
  - Listening on the watch could overwrite newer progress from another device.

With thanks to @idanbauer, @Ayfteyd7Od, @treyg and @pbzdyl for the fixes and
features in this release.
```
