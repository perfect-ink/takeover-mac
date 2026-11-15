# App icon

`logo.svg` is the source for the app icon: a blue macOS squircle with a round
vault door. To regenerate the PNGs in `Takeover/Assets.xcassets/AppIcon.appiconset`:

```sh
for n in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $n -h $n design/logo.svg \
    -o Takeover/Assets.xcassets/AppIcon.appiconset/icon_$n.png
done
```
