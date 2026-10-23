# Public exception tag fixtures

These small modules exercise the native public tag adapter: empty and numeric
payloads, aliases, independent identities, cross-instance calls and unsupported
typed/vector signatures. Basic nullable reference tag imports and exports are
accepted; scalar carriers cannot satisfy a different payload kind.
`exception_refs` checks captured exception
references across instances and synchronous/asynchronous interpreters.

The original fixtures used wasm-tools 1.254.0. Parse changed fixtures with the
currently pinned wasm-tools 1.262.0:

```sh
for file in test/fixtures/host_tags/*.wat; do
  .toolchains/bin/wasm-tools parse "$file" -o "${file%.wat}.wasm"
  .toolchains/bin/wasm-tools validate "${file%.wat}.wasm"
done
```

`test/support/host_tag_fixtures.dart` embeds the public-adapter fixtures as base64
for tests that compile to JavaScript. When updating a public fixture, regenerate
its base64 entry from the matching `.wasm`. The native-only `exception_refs`
test reads its binary directly.
