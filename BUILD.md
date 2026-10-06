# WatchShelf - build & run from the command line

No editor, no IDE, no VS Code. Everything is terminal + the `Makefile`. Verified
against **Connect IQ SDK 9.2.0** on macOS; the app builds clean for the Tactix 8
(`fenix8solar51mm`).

## 0. Prerequisites (one-time)

- **Java 17+** on your PATH - `java -version` must work. It's the Homebrew JDK
  here; if `java` isn't found, add to your shell profile:
  `export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"`.
  (The Makefile also prepends this path defensively.)
- **Connect IQ SDK** - installed via the Connect IQ **SDK Manager** (a small
  standalone app, *not* VS Code). Already done (SDK 9.2.0). The Makefile finds it
  automatically from `~/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg`,
  so it keeps working when you update the SDK.
- **Your Tactix 8 device bundle** - in the SDK Manager → Devices, the entry
  **“fēnix 8 47mm / 51mm / tactix 8 47mm / 51mm / quatix 8 47mm / 51mm”**
  (device id `fenix8solar51mm`). Already installed.
- **ffmpeg** on PATH - for the transcode sidecar. Already present.

## 1. Signing key (one-time)

```
make key
```

Creates `developer_key.der` (gitignored). **Reuse the same key forever** - build
and store submissions must be signed with it, or existing installs won't update.
(`make build` auto-creates it on first run if missing.)

## 2. Build for your Tactix 8

```
make build              # -> bin/WatchShelf.prg  (device fenix8solar51mm)
make build DEVICE=venu3 # build for a different installed device
```

## 3. Run in the simulator

```
make sim                # builds, launches the simulator, loads the app
```

WatchShelf is an **audio content provider**, so in the sim it lives under the
**media / music** UI, not as a normal app icon. To test against a plain-HTTP
sidecar, disable the sim's *Settings → Use Device HTTPS Requirements*. On-watch
login (step 5) works in the sim too; the settings below (step 4) are an
alternative if you'd rather not log in.

## 4. Config (on-watch login, or phone settings once published)

Normally you just **log in on the watch** (see step 5) with the sidecar's URL,
your ABS username, and your ABS password — no settings screen needed for a
sideloaded install.

The two Properties below exist only for the **Connect IQ Store** path (phone
settings via Garmin Connect Mobile / Express aren't reachable for a sideloaded
app), and are a fallback if you'd rather not log in on-watch:

| Setting | Example |
|---|---|
| WatchShelf URL | `https://watchshelf.example.com` (the **sidecar's** URL, not ABS's) |
| Audiobookshelf API key | a long-lived ABS key (Settings → API Keys) with **download** permission |

## 5. Sideload to the Tactix 8

1. `make build`
2. Connect the watch by USB - it mounts as a drive.
3. Copy `bin/WatchShelf.prg` to the watch's **`GARMIN/APPS/`** folder.
4. Eject. WatchShelf appears under the watch's **Music / audio providers**.
5. Open it → **Log in** → enter the **sidecar's** URL (not ABS's) + your ABS
   username + password.
6. **On-device the sidecar MUST be HTTPS on port 443 with a valid CA cert** -
   self-signed / LAN-only / custom-port fails the watch's audio downloader even
   though it works in the sim. ABS itself does NOT need to be exposed - the watch
   never talks to it directly (see `sidecar/GETTING_STARTED.md`).

## 6. Run the sidecar

```
cd sidecar
cp .env.example .env      # fill in ABS_URL (that's the only required setting)
npm start                 # needs ffmpeg on PATH
```

Expose it over HTTPS with whatever reverse proxy you already run - a plain
step-by-step guide for Cloudflare Tunnel, nginx, Apache, Caddy, and Traefik is in
[sidecar/GETTING_STARTED.md](sidecar/GETTING_STARTED.md).

## 7. Store package

```
make package              # -> bin/WatchShelf.iq
```

Compiles for **every** device in `manifest.xml` (93 targets as of 6 October 2026).
Open SDK Manager and let all device downloads/updates finish before building;
building during a refresh can temporarily report installed devices as unrecognized.
The Connect IQ Store upload also validates which listed devices can run an audio app.

For future watches, refresh SDK Manager's device catalog, then inspect each new
device's `compiler.json` under
`~/Library/Application Support/Garmin/ConnectIQ/Devices/`. Add its exact `deviceId`
to the manifest only if `appTypes` contains `audioContentProvider` and a supported
`partNumbers[].connectIQVersion` meets the manifest's minimum API version. Use the
`displayName` to identify shared targets; do not invent separate IDs for every
marketed size or brand. Compare with Garmin's
[Media API supported devices](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media.html),
then run `make package` to validate the entire set.

Upload `bin/WatchShelf.iq` as an update to the existing Connect IQ Store app, using
the existing app ID and signing key. The manifest change alone does not update
the live store listing. Check the store's compatible-device list after acceptance.

Compatibility build verified on 6 October 2026 with SDK 9.2.0: all 151 eligible
device/firmware builds across 93 manifest targets passed. Warnings were limited
to automatic launcher-icon scaling and one D2 Delta PX firmware variant on API
3.0.3 being skipped (below our 3.1.0 minimum). This verifies compilation, not
physical-watch playback or acceptance of the update by the store.

## Make targets

| Target | Does |
|---|---|
| `make build [DEVICE=id]` | debug `.prg` (default `fenix8solar51mm`) |
| `make sim [DEVICE=id]` | build + launch simulator |
| `make package` | store `.iq` across all manifest devices |
| `make key` | generate the signing key |
| `make devices` | list installed device ids |
| `make clean` | remove `bin/` and `gen/` |

## Verified against a live ABS server

Ran the sidecar against a real Audiobookshelf (behind Cloudflare): `/login` proxy,
`/libraries`, `/list` (all books + author/series-filtered), `/authors`, `/series`,
`/files`, on-demand `/transcode` chunks, and the `/progress` forwarder (ABS
`currentTime` confirmed updated on read-back) all pass end-to-end.

## Still to confirm on the sim/device

- **On-watch playback** - that a downloaded chunk actually plays through the native
  player to Bluetooth.
- **Long books = many chunks** - a 25-hour book splits into ~50 chunks; sync works
  but is slow, and hasn't been timed end-to-end on real hardware.
