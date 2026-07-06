# Store assets

Promotional artwork for the Connect IQ store listing (and repo social preview).
All images are generated programmatically by [`generate.py`](generate.py) — edit
that script and re-run it to change branding, then commit the regenerated PNGs.

Brand: orange `#FF8000` + charcoal + cream, bookshelf-with-play-badge motif
(matches the in-app launcher/provider icons under `resources/drawables/`).

## Files and where each one goes

| File | Size | Connect IQ store slot |
|------|------|-----------------------|
| `icon_500.png` | 500×500 | **App Icon** (required; sRGB, ~10px padding) |
| `icon_128_on_device.png` | 128×128 | Optional on-device store icon |
| `hero_1440x720.png` | 1440×720 | **Hero Image** |
| `screen_1_library.png` | 900×900 | **Screenshot** — library browse |
| `screen_2_playmenu.png` | 900×900 | **Screenshot** — "Play downloaded" book list |
| `screen_3_bookactions.png` | 900×900 | **Screenshot** — per-book Resume / Play from start / Delete |
| `screen_4_player.png` | 900×900 | **Screenshot** — now-playing player |
| `cover_1280x640.png` | 1280×640 | Not a CIQ field — GitHub social preview / README banner |

The `screen_*` images are polished **mockups** that reproduce the real UI, not
literal device captures. Garmin's store accepts promotional screenshots; for
pixel-true captures instead, use the simulator's "Save Screen" (454×454) or a
real device.

## Regenerate

```
python3 -m pip install pillow      # if needed
python3 store-assets/generate.py   # writes the PNGs into this folder
```

Requires system fonts (Arial) present on macOS; adjust the `font()` paths in
`generate.py` on other platforms.

## Specs reference

- App icon 500×500, on-device 128×128, hero 1440×720 — per Garmin's
  [Connect IQ brand guidelines](https://developer.garmin.com/brand-guidelines/connect-iq/).
