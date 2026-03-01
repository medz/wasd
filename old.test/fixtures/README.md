# Test Fixtures

This directory stores large and external fixture artifacts used by regression tests.

## Setup

```bash
tool/setup_test_fixtures.sh
```

Optional TinyGo fixture build:

```bash
tool/setup_test_fixtures.sh --with-tinygo
```

## Layout

- `doom/`: Doom smoke-test fixtures (`doom.wasm`, `doom1.wad`)
- `community/`: community-generated Wasm fixtures (`go`, optional `tinygo`)
- `src/`: source files used to build community fixtures

TinyGo fixture source is fetched from the official TinyGo repository:
`https://github.com/tinygo-org/tinygo` (`src/examples/wasm/main/main.go`) and cached under
`test/fixtures/src/tinygo_org_wasm_main/`.

Large binary fixtures are intentionally not tracked in git.
