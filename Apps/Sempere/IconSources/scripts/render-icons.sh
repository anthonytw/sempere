#!/usr/bin/env bash
# Render the icon sources (../*.svg) to opaque 1024x1024 PNGs in the app's asset catalogs.
# Needs rsvg-convert (brew install librsvg) and ImageMagick (brew install imagemagick).
#   Apps/Sempere/IconSources/scripts/render-icons.sh
# App Store icons must have no alpha channel: each SVG paints a full-bleed background, and the
# result is flattened onto it anyway with the alpha channel removed.
set -euo pipefail
cd "$(dirname "$0")/.."
assets=../SempereApp/Assets.xcassets

# source name -> destination "set/file"
render() {
  local src=$1 dest=$2 bg=$3
  mkdir -p "$assets/$(dirname "$dest")"
  rsvg-convert -w 1024 -h 1024 -b "$bg" "$src.svg" \
    | magick png:- -background "$bg" -alpha remove -alpha off -strip -depth 8 PNG24:"$assets/$dest"
  echo "$assets/$dest"
}

render keyhole-nib        AppIcon.appiconset/AppIcon.png        '#0d1424'
render keyhole-nib-dark   AppIcon.appiconset/AppIcon-Dark.png   '#03050a'
render keyhole-nib-tinted AppIcon.appiconset/AppIcon-Tinted.png '#000000'
render cemetery-door      CemeteryDoor.appiconset/CemeteryDoor.png '#0d1424'
render shadow-s           ShadowS.appiconset/ShadowS.png        '#fbf6ea'
render ink-wind           InkWind.appiconset/InkWind.png        '#0d1424'

# Small previews for Settings' icon picker (an app-icon set cannot be loaded as an image).
preview() {
  local src=$1 name=$2 bg=$3
  mkdir -p "$assets/$name.imageset"
  rsvg-convert -w 256 -h 256 -b "$bg" "$src.svg" \
    | magick png:- -background "$bg" -alpha remove -alpha off -strip -depth 8 PNG24:"$assets/$name.imageset/$name.png"
  printf '{\n  "images" : [\n    { "filename" : "%s.png", "idiom" : "universal" }\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' "$name" > "$assets/$name.imageset/Contents.json"
}
preview keyhole-nib   IconPreviewKeyholeNib   '#0d1424'
preview cemetery-door IconPreviewCemeteryDoor '#0d1424'
preview shadow-s      IconPreviewShadowS      '#fbf6ea'
preview ink-wind      IconPreviewInkWind      '#0d1424'
