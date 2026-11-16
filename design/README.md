# App icon

`icon-original.png` is the original detailed vault artwork. `build_icon.py`
turns it into the app icon: it makes the door a true circle, drops the latch
bar on the right, moves the hinges to the door's edge and places the vault on
the blue squircle. To regenerate every size in
`Takeover/Assets.xcassets/AppIcon.appiconset`:

```sh
python3 design/build_icon.py   # needs Pillow and numpy
```
