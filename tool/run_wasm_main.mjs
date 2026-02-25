import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

async function main() {
  const [modulePath, wasmPath, ...args] = process.argv.slice(2);
  if (!modulePath || !wasmPath) {
    process.stderr.write(
      'usage: node tool/run_wasm_main.mjs <module.mjs> <module.wasm> [args...]\n',
    );
    process.exit(2);
  }

  const moduleUrl = pathToFileURL(path.resolve(modulePath)).href;
  const wasmBytes = await readFile(path.resolve(wasmPath));
  const bridge = await import(moduleUrl);
  const compiledApp = await bridge.compile(wasmBytes);
  const app = await compiledApp.instantiate({});
  app.invokeMain(...args);
}

main().catch((error) => {
  const message = error?.stack ?? String(error);
  process.stderr.write(`${message}\n`);
  process.exit(1);
});
