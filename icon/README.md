The app icon: `stacks2.svg` is the source, a variation on the Stacks icon.
`Stacks2.icns` is made from it by rendering the SVG at 1024 px, masking it to
the rounded tile, resizing it to each iconset size, and running
`iconutil -c icns`. `./bundle` copies `Stacks2.icns` into the app.
