# Connect IQ store listing — b42 (prepared, not yet published)

Physical Venu 4 charging and unattended Wi-Fi behavior still need validation.
Upload the matching b42 package before copying these blocks into the store
fields. Updating this file or the store text does not update the installed
binary. Confirm the accepted package and the on-watch build tag match the notes.

**The store rejects `<` and `>`** ("Illegal characters found") - the menu
separators here are spelled out in words for that reason. Keep every block
plain ASCII: em dashes and curly quotes are not worth risking a second
rejection round-trip. "What's New" allows 4000 characters.

---

## App name

```
WatchShelf
```

## Short description

```
Listen to your own Audiobookshelf library on your watch - offline, with two-way progress sync.
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
has to be exposed to the internet - only the sidecar does.

WHAT YOU CAN DO
  - Browse your whole library: all books, by author, by series, by collection
  - Continue Listening picks up what you started on any device
  - Download only the part you have not heard yet
  - Choose playback speed per book - 1.0x, 1.25x, 1.5x, 1.75x or 2.0x - from
    the book's own menu, after it is already on your watch
  - Browse podcast shows and episodes; optionally keep 1-5 unfinished episodes
    per show, with download order and speed choices
  - Optional removal of finished automatic episodes after progress is confirmed;
    Keep on watch protects an episode from automatic removal
  - Chapter skip, 30-second jumps, and whole-book progress on the player
  - Optional sleep timer, from 5 minutes to 2 hours; stops after the current part
  - Two-way progress sync: finish a chapter on the watch, carry on in the car
  - Log in on the watch; only a token is stored, never your password
  - Optional shared-secret header so a reverse proxy can lock the sidecar to
    your watch alone

GOOD TO KNOW
  - Downloads take a while. A long book is many small chunks by design - that
    is what keeps it within a watch's memory.
  - Podcast episodes must already be downloaded in Audiobookshelf.
  - Automatic podcast downloads start off and request sync while charging.
    Garmin controls the timing; Sync now also works without charging.
  - The player's time bar covers the current part; whole-book percentage is
    shown on the artist line.

Open source, MIT licensed: github.com/JediBrooker/WatchShelf
```

---

## What's New — b42

> Covers **everything since b35**, the previous public build. Several releases
> landed the same day, so most users are jumping the whole span at once and the
> notes have to read as one list rather than a changelog.
>
> The backend line is first on purpose: anyone updating the app without updating
> the sidecar loses all downloads, so it must not sit under the features.

```
WATCHSHELF b42

UPDATE YOUR SIDECAR FIRST

This release needs a newer WatchShelf sidecar. If you update the watch app
without updating the sidecar, your downloads will fail until you do.

  docker compose pull && docker compose up -d

Prebuilt image: ghcr.io/jedibrooker/watchshelf:latest (amd64 and arm64).

New since b35:

NEW

  Automatic podcast downloads (off by default)
  Choose a podcast library, Shows, a show, then Automatic downloads. Keep 1-5
  unfinished episodes per show, with order and speed choices. Existing unfinished
  episodes stay. Manage up to 10 shows under Downloaded, Podcast downloads.
  Optional finished-episode removal waits for confirmed progress; Keep on watch
  protects an episode. Automatic sync requires charging; Garmin decides timing.
  Sync now also works without charging. Requires the updated sidecar.

  Sleep timer
  Choose Off, 5, 15, 20, 30, 45, 60, 90 or 120 minutes from a downloaded
  book's menu or phone settings. Playback stops at the end of the current part,
  up to about 3 minutes later. Starting or resuming playback restarts the timer.

  Set up from your phone
  Garmin Connect, then WatchShelf, then Settings, takes your WatchShelf URL
  and an Audiobookshelf API key, and the watch then needs no typing at all.
  The app offers this the first time you open it, instead of sending you
  straight to the on-watch keyboard. (Connect IQ Store installs only.)

  Playback speed, per book
  1.0x, 1.25x, 1.5x, 1.75x or 2.0x, chosen from a downloaded book's own menu
  next to Resume and Play from start. A watch cannot change the speed of audio
  it is already holding, so a speed you have not used before has to be fetched -
  but WatchShelf keeps the previous one when there is room, so switching BACK to
  a speed you already have is instant. The menu shows which speeds are on the
  watch.

  Podcasts
  Podcast libraries appear alongside your audiobooks. Each show browses like an
  author and each episode like a book, with progress syncing per episode.
  Episodes must already be downloaded in Audiobookshelf.

  Lock the sidecar to your watch
  Optional shared-secret header, so a reverse proxy can reject anything that is
  not your watch. Set it under Downloaded, then Proxy header, or from Garmin
  Connect.

  Prebuilt sidecar images
  ghcr.io/jedibrooker/watchshelf:latest, for amd64 and arm64 - so a Raspberry Pi
  or ARM NAS works without building anything.

FIXED

  Phone API-key setup
  The updated sidecar accepts Audiobookshelf API keys entered in Garmin Connect
  settings, including for SSO accounts. Logging out and back in is no longer
  necessary. Malformed credentials are rejected before they reach the downloader.

  Startup crash introduced in b40
  The "Made in Australia" row now uses plain text. Its flag icon triggered
  "Media Error Occurred" when opening the app on fenix 8 47 mm AMOLED.

  Watch compatibility
  The package includes all 93 supported audio-provider targets from the
  October 2026 device catalog, including the fenix 9 family.

  Long books would not play
  Books with several hundred parts could hang on a blank player screen or fail
  outright. Building the playlist was too slow and the watch killed it. Found
  and fixed by @Ayfteyd7Od and @idanbauer.

  Login crashed on vivoactive 4 / 4s and Venu / Venu D
  Those watches have no on-screen keyboard, and the app crashed the moment you
  started logging in. They now get an on-watch character wheel - though the
  phone setup above is far quicker if you can use it.

  Progress could go backwards
  Listening on the watch could overwrite a newer position set on another device.
  The watch now checks the server before pushing.

  Also: if a progress conflict is ever detected, a "Progress conflicts" row
  appears under Downloaded. It is diagnostic only - if you see it, please open
  an issue on GitHub.

With thanks to @alt-13, @idanbauer, @Ayfteyd7Od, @treyg and @pbzdyl, whose fixes and
features make up most of this release.
```
