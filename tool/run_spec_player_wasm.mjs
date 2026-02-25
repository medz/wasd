import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

async function main() {
  const [modulePath, wasmPath, manifestPath, outputJsonPath] =
    process.argv.slice(2);
  if (!modulePath || !wasmPath || !manifestPath || !outputJsonPath) {
    process.stderr.write(
      'usage: node tool/run_spec_player_wasm.mjs <module.mjs> <module.wasm> <manifest.json> <output.json>\n',
    );
    process.exit(2);
  }

  const resolvedModulePath = path.resolve(modulePath);
  const resolvedWasmPath = path.resolve(wasmPath);
  const resolvedManifest = path.resolve(manifestPath);
  const resolvedOutput = path.resolve(outputJsonPath);

  let resultJson = null;
  let errorJson = null;
  let resultResolve;
  let resultReject;
  const resultReady = new Promise((resolve, reject) => {
    resultResolve = resolve;
    resultReject = reject;
  });

  globalThis.wasdSpecReadText = (targetPath) =>
    fs.readFileSync(path.resolve(String(targetPath)), 'utf8');
  globalThis.wasdSpecReadBinary = (targetPath) =>
    new Uint8Array(fs.readFileSync(path.resolve(String(targetPath))));
  globalThis.wasdSpecSetResult = (payload) => {
    resultJson = String(payload);
    resultResolve();
  };
  globalThis.wasdSpecSetError = (payload) => {
    errorJson = String(payload);
    resultReject(new Error(errorJson));
  };

  const bridge = await import(pathToFileURL(resolvedModulePath).href);
  const wasmBytes = fs.readFileSync(resolvedWasmPath);
  const compiled = await bridge.compile(wasmBytes);
  const app = await compiled.instantiate({});

  let executionError = null;
  try {
    app.invokeMain(`--player-manifest=${resolvedManifest}`);
    await resultReady;
  } catch (error) {
    executionError = error;
  }

  if (resultJson == null) {
    if (executionError != null) {
      throw executionError;
    }
    throw new Error('player did not provide result json');
  }

  fs.mkdirSync(path.dirname(resolvedOutput), { recursive: true });
  fs.writeFileSync(resolvedOutput, resultJson);

  if (errorJson != null) {
    process.stderr.write(`${errorJson}\n`);
    process.exit(1);
  }

  const parsed = JSON.parse(resultJson);
  const failed = parsed?.totals?.files_failed ?? 0;
  if (failed > 0 || executionError != null) {
    process.exit(1);
  }
}

main().catch((error) => {
  const message = error?.stack ?? String(error);
  process.stderr.write(`${message}\n`);
  process.exit(1);
});
