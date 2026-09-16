# Everywhere icon

`AppIcon.svg` is the original vector artwork supplied as `~/Downloads/Everywhere.svg`.
It shows a white search lens containing three file-index rows on a rounded blue gradient tile.

`Scripts/make-icon.swift` renders the SVG directly with AppKit at every required pixel
size, from 16 through 1024, and packages the results into `AppIcon.icns`. It also writes
`AppIcon.png` and `AppIcon.icns.png` as 1024-pixel previews. Transparency is preserved.
Run `make app` to regenerate the icon and bundle it in the application.

The menu bar icon in `StatusItemController.statusIcon()` uses the same lens, handle,
and three index rows, with the tile, gradients, and shadows removed. Its vector geometry
is scaled to a 16-point symbol inside an 18-point canvas. It is a macOS template image,
so the system supplies the appropriate color for light, dark, and selected menu bars.
The window title bar uses the bundled application icon.
