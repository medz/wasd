# DOOM Flutter Example

This example targets Flutter desktop and web hosts.

## Run (macOS)

```sh
flutter run -d macos
```

## Run (Chrome)

The web worker input path uses `SharedArrayBuffer`, so Chrome must run with
`COOP/COEP` response headers enabled:

```sh
flutter run -d chrome \
  --web-hostname=127.0.0.1 \
  --web-port=8125 \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```

Without these headers, DOOM can render on web, but keyboard input will not work.
