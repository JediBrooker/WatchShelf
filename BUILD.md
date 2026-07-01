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
**media / music** UI, not as a normal app icon. To test against a plain-HTTP ABS,
disable the sim's *Settings → Use Device HTTPS Requirements*. Set the four app
settings (below) via the simulator's app-settings editor.

## 4. App settings (sim or watch)

Four string settings drive the app:

| Setting | Example |
|---|---|
| Audiobookshelf server URL | `https://abs.example.com` |
| Audiobookshelf API key | a long-lived ABS key (Settings → API Keys) with **download** permission |
| Transcode sidecar URL | `https://abs.example.com/watchshelf-transcode` |
| Sidecar shared key | matches the sidecar's `SIDECAR_KEY` |

On the watch these are edited in **Garmin Connect Mobile** / **Garmin Express**
(watch → WatchShelf → Settings).

## 5. Sideload to the Tactix 8

1. `make build`
2. Connect the watch by USB - it mounts as a drive.
3. Copy `bin/WatchShelf.prg` to the watch's **`GARMIN/APPS/`** folder.
4. Eject. WatchShelf appears under the watch's **Music / audio providers**.
5. **On-device the ABS server and the sidecar MUST be HTTPS on port 443 with a
   valid CA cert** - self-signed / LAN-only / custom-port fails the watch's audio
   downloader even though it works in the sim.

## 6. Run the sidecar

```
cd sidecar
cp .env.example .env      # fill ABS_URL, ABS_TOKEN, SIDECAR_KEY, PORT
npm start                 # needs ffmpeg on PATH
```

Mount it behind your reverse proxy so it shares the ABS `:443` cert - see
`sidecar/Caddyfile.snippet` (Caddy) or the nginx block in the same file.

## 7. Store package (later)

```
make package              # -> bin/WatchShelf.iq
```

Compiles for **every** device in `manifest.xml`, so all their bundles must be
installed in the SDK Manager first (some may still be downloading). The Connect
IQ Store upload also validates which listed devices can actually run an audio app.

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

Ran the ABS client + sidecar against a real Audiobookshelf (v2.35.1, behind
Cloudflare): token auth, `/api/libraries` → items → item-detail shapes, direct
MP3 download (`206 audio/mpeg`), **m4b → ADTS** convert, and the **`/progress`
forwarder** (ABS `currentTime` confirmed updated on read-back) all pass.

## Still to confirm on the sim/device

- **On-watch playback** - that a downloaded track's `Media.ContentRef` actually
  plays through the native player to Bluetooth, including **ADTS** (m4b) output.
- **Cloudflare + the watch's UA** - the watch's real User-Agent isn't blocked by
  Cloudflare bot protection. In testing a `Garmin`/empty UA passed (only the
  literal `Python-urllib` was 403'd), so this is low risk - but if downloads
  403 on-device, allowlist the Garmin UA (or `/api/*`) in Cloudflare.
- **Large single-file books** - a multi-hour single MP3 with no chapters downloads
  as one big track; watch reliability there (multi-file / chaptered books split
  into smaller tracks and are fine).
