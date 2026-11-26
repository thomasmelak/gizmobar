# App icon

`AppIcon.svg` is the source. A wireframe globe with an orbiting satellite
(the 3D engine) above a glass bar with workspace pills and a spectrum, in
the Tefer colors.

`AppIcon-1024.png` and `AppIcon.icns` are rendered from it; `scripts/bundle.sh`
copies the `.icns` into the app. To re-render on a Mac after editing the SVG:

```sh
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s AppIcon.svg -o AppIcon.iconset/icon_${s}x${s}.png
  rsvg-convert -w $((s*2)) -h $((s*2)) AppIcon.svg -o AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset && rm -r AppIcon.iconset
rsvg-convert -w 1024 -h 1024 AppIcon.svg -o AppIcon-1024.png
```

(`brew install librsvg` for `rsvg-convert`.)
