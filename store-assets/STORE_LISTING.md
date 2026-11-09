# Connect IQ store listing — b45 (prepared, not yet published)

Physical Venu 4 charging and unattended Wi-Fi behavior still need validation.
Upload the matching b45 package before copying these blocks into the store
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

## What's New — b45

> A changelog, newest build first, covering **everything since b35**, the
> previous public build. Most users jump the whole span at once, so every build
> is listed rather than only the latest. Add each new build at the top.
>
> The sidecar update is first on purpose: anyone updating the app without
> updating the sidecar loses all downloads. The default `docker-compose.yml`
> builds from source, so `docker compose pull` alone does not update it; each
> install method gets its own command.

```
WATCHSHELF b45

UPDATE YOUR SIDECAR FIRST

This release needs a newer WatchShelf sidecar. Update it before the watch app,
or downloads will fail. In your sidecar folder:

  Prebuilt image (docker-compose.ghcr.yml):
    docker compose -f docker-compose.ghcr.yml pull
    docker compose -f docker-compose.ghcr.yml up -d

  Built from source (docker-compose.yml):
    git pull
    docker compose up -d --build

  Installed with install.sh: run the installer again.

Image: ghcr.io/jedibrooker/watchshelf:latest (amd64 and arm64).

CHANGELOG SINCE b35

b45
- Deleting a long book no longer sits at 0%. The progress bar moves as it goes.

b44
- New Last sync row under Downloaded shows what the latest sync did: start,
  end or Did not finish, parts, retries and the last error code. Include it
  when reporting a sync problem.
- Sidecar: a network blip while renewing your session is no longer reported
  as an expired session.

b43
- A failed part no longer cancels a download. WatchShelf retries it, then
  Sync now continues from the same part without selecting the book again.

b42
- Automatic podcast downloads, off by default. Choose a podcast library,
  Shows, a show, then Automatic downloads. Keep 1-5 unfinished episodes per
  show, with order and speed choices. Optional removal of finished episodes
  waits for confirmed progress. Automatic sync needs the watch on charge;
  Sync now works without. Manage up to 10 shows under Downloaded, Podcast
  downloads.
- Sleep timer: Off, 5, 15, 20, 30, 45, 60, 90 or 120 minutes, from a book's
  menu or phone settings. Playback stops at the end of the current part.
- Fixed: Audiobookshelf API keys entered in Garmin Connect settings now work,
  including for SSO accounts.

b41
- Fixed: "Media Error Occurred" when opening the app on fenix 8 47 mm AMOLED,
  introduced in b40.

b40
- All 93 audio-capable Garmin watches supported, including the fenix 9 family.
- "Made in Australia" row at the foot of the Downloaded menu.

b39
- First run offers setup from your phone (Garmin Connect, WatchShelf,
  Settings) before the on-watch keyboard. Connect IQ Store installs only.

b38
- Change a book's playback speed after downloading it. WatchShelf keeps the
  previous speed when there is room, so switching back is instant.

b37
- Playback speed per book: 1.0x, 1.25x, 1.5x, 1.75x or 2.0x.

b36
- Podcasts: shows browse like authors and episodes like books, with progress
  per episode. Episodes must be downloaded in Audiobookshelf.
- Optional proxy header locks the sidecar to your watch. Set it under
  Downloaded, Proxy header, or in Garmin Connect.
- Prebuilt sidecar images for amd64 and arm64.
- Fixed: books with several hundred parts hung or failed to play. Found and
  fixed by @Ayfteyd7Od and @idanbauer.
- Fixed: login crashed on vivoactive 4 / 4s and Venu / Venu D. They now get
  an on-watch character wheel.
- Fixed: listening on the watch could overwrite a newer position from
  another device.

With thanks to @alt-13, @idanbauer, @Ayfteyd7Od, @treyg and @pbzdyl, whose
fixes and features make up most of this release.
```
