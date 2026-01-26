# Build Resources

This directory contains build resources for the installer:

- `icon.ico` - Windows application icon (256x256)
- `installer-sidebar.bmp` - Optional sidebar image for NSIS installer (164x314)

## Creating Icons

### Windows (.ico)
1. Create a 256x256 PNG image
2. Use an online converter or ImageMagick:
   ```
   magick convert icon.png -define icon:auto-resize=256,128,64,48,32,16 icon.ico
   ```
