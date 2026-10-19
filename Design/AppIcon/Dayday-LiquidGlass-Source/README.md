# Dayday Liquid Glass icon source

This folder is the editable source for the Dayday app icon. The five SVG files are intentionally
flat, single-purpose layers so that Icon Composer — not the source artwork — owns translucency,
specular highlights, and refraction.

## Layer order

1. `01-Background.svg` — pale lavender foundation.
2. `02-Primary-D.svg` — the solid, rounded Dayday mark.
3. `03-Outer-Trace.svg` — the longer time trace.
4. `04-Inner-Trace.svg` — the nearer time trace.
5. `05-Record-Dot.svg` — the current-recording marker.

## Icon Composer setup

1. Create a new 1024 × 1024 macOS icon document in Icon Composer.
2. Import the SVGs in the order above, keeping every SVG as an independent layer.
3. Use a light lavender regular glass treatment for the primary `D`; use clear or regular glass
   treatment for the two white traces and dot. Keep the background mostly opaque to preserve
   contrast in Light, Dark, Clear, and Tinted appearances.
4. Keep refraction restrained. The mark must remain legible at 16 px; the record dot must not
   become a bright focal point.
5. Export the document as `Dayday.icon` into this directory and add it to the Xcode target as the
   macOS 26+ app icon source.

The asset catalog in `Sources/DaydayApp/Assets.xcassets` is the static macOS 14–25 fallback.
It is deliberately derived from the same layer source rather than from an AI-generated bitmap.
