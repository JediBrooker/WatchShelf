WatchShelf icons (binary PNGs - add these two files to this folder)
===================================================================

drawables.xml references two bitmaps that you must supply as PNGs:

  launcher_icon.png   - the app launcher icon
  provider_icon.png   - the audio-provider icon in the device media menu

Recommended: a simple book-on-a-shelf / bookmark glyph in orange (#FF8000)
on transparent or black.

Sizes: Connect IQ scales a single source per device, but to be safe export a
60x60 px and a 40x40 px variant and let the resource compiler pick, OR just
ship one 60x60 px PNG named as above - the SDK will downscale.

Quick generation from the repo's app-icon SVG (if you have one) with rsvg /
ImageMagick:

  rsvg-convert -w 60 -h 60 app-icon.svg -o resources/drawables/launcher_icon.png
  cp resources/drawables/launcher_icon.png resources/drawables/provider_icon.png

Keep them small (indexed-color PNG, few KB) - the owner prizes lightweight.
