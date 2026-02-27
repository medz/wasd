# Doom Flutter Example

This Flutter app runs Doom (`doom.wasm`) through WASD with bundled assets.

## Run

```bash
flutter pub get
tool/setup_assets.sh
flutter run -d macos
```

Replace `-d macos` with your desktop target (`linux`, `windows`, etc.).

## Assets

`tool/setup_assets.sh` downloads:

- `assets/doom/doom.wasm`
- `assets/doom/doom1.wad`

These large binary assets are intentionally not tracked in git.
