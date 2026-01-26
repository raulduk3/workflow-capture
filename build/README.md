# Build Resources

This directory contains build resources for the installer:

- `icon.ico` - Windows application icon (256x256)
- `icon.icns` - macOS application icon
- `installer-sidebar.bmp` - Optional sidebar image for NSIS installer (164x314)

## Creating Icons

### Windows (.ico)
1. Create a 256x256 PNG image
2. Use an online converter or ImageMagick:
   ```
   magick convert icon.png -define icon:auto-resize=256,128,64,48,32,16 icon.ico
   ```

### macOS (.icns)
1. Create a 1024x1024 PNG image
2. Use iconutil:
   ```
   mkdir icon.iconset
   sips -z 16 16 icon.png --out icon.iconset/icon_16x16.png
   sips -z 32 32 icon.png --out icon.iconset/icon_16x16@2x.png
   sips -z 32 32 icon.png --out icon.iconset/icon_32x32.png
   sips -z 64 64 icon.png --out icon.iconset/icon_32x32@2x.png
   sips -z 128 128 icon.png --out icon.iconset/icon_128x128.png
   sips -z 256 256 icon.png --out icon.iconset/icon_128x128@2x.png
   sips -z 256 256 icon.png --out icon.iconset/icon_256x256.png
   sips -z 512 512 icon.png --out icon.iconset/icon_256x256@2x.png
   sips -z 512 512 icon.png --out icon.iconset/icon_512x512.png
   sips -z 1024 1024 icon.png --out icon.iconset/icon_512x512@2x.png
   iconutil -c icns icon.iconset
   ```
