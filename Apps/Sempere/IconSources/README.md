# App icon sources

Vector sources of the app icons (1024 × 1024 SVG), so the PNGs in
`../SempereApp/Assets.xcassets` can be regenerated and tweaked.

| Source | Asset | Where it shows |
| --- | --- | --- |
| `keyhole-nib.svg` | `AppIcon` (default) | home screen, light |
| `keyhole-nib-dark.svg` | `AppIcon` dark variant | dark appearance |
| `keyhole-nib-tinted.svg` | `AppIcon` tinted variant | tinted appearance (grayscale on black) |
| `cemetery-door.svg` | `CemeteryDoor` | alternate icon |
| `shadow-s.svg` | `ShadowS` | alternate icon |
| `ink-wind.svg` | `InkWind` | alternate icon |

The alternates are chosen in Settings → App Icon (`AppIconSettings.swift`) and listed in the
app target's `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` build setting. Adding one means a
new SVG, a line in `scripts/render-icons.sh`, a case in `AppIconChoice` and the build setting;
`AppIconTests` fails if they disagree. Mac Catalyst has no alternate icons; the Mac app uses the
default icon.

## Rendering

```bash
Apps/Sempere/IconSources/scripts/render-icons.sh
```

Needs `rsvg-convert` (`brew install librsvg`) and ImageMagick. It writes the opaque (no alpha
channel, as the App Store requires) 1024 px PNGs into the asset catalog, plus the 256 px preview
image sets the Settings picker shows. Check a change at small sizes too (29 and 40 px are the
smallest places the icon appears): render, shrink with ImageMagick and look.

## Credits

The "S" in `shadow-s.svg` is the outline of the glyph from **Playfair Display** Italic, weight 700
(Claus Eggers Sørensen, Copyright 2017 The Playfair Display Project Authors), licensed under the
[SIL Open Font License 1.1](https://openfontlicense.org). The glyph is embedded as path data, so the
icon does not depend on an installed font; the font file is not part of this repository. Source:
<https://github.com/google/fonts/tree/main/ofl/playfairdisplay>. The path was extracted with
fontTools (`instantiateVariableFont` at `wght=700`, `SVGPathPen`).
