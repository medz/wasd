import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

async function main() {
  const [compiledJsPath, manifestPath, outputJsonPath] = process.argv.slice(2);
  if (!compiledJsPath || !manifestPath || !outputJsonPath) {
    process.stderr.write(
      'usage: node tool/run_spec_player_js.mjs <compiled.js> <manifest.json> <output.json>\n',
    );
    process.exit(2);
  }

  const resolvedScript = path.resolve(compiledJsPath);
  const resolvedManifest = path.resolve(manifestPath);
  const resolvedOutput = path.resolve(outputJsonPath);

  let resultJson = null;
  let errorJson = null;
  let completeResolve;
  let completeReject;
  const complete = new Promise((resolve, reject) => {
    completeResolve = resolve;
    completeReject = reject;
  });

  globalThis.wasdSpecReadText = (targetPath) =>
    fs.readFileSync(path.resolve(String(targetPath)), 'utf8');
  globalThis.wasdSpecReadBinary = (targetPath) =>
    new Uint8Array(fs.readFileSync(path.resolve(String(targetPath))));
  globalThis.wasdSpecSetResult = (payload) => {
    resultJson = String(payload);
  };
  globalThis.wasdSpecSetError = (payload) => {
    errorJson = String(payload);
  };

  globalThis.dartMainRunner = (callMain, _args) => {
    Promise.resolve(callMain([`--player-manifest=${resolvedManifest}`]))
      .then(() => completeResolve())
      .catch((error) => completeReject(error));
  };

  let executionError = null;
  await import(pathToFileURL(resolvedScript).href);
  try {
    await complete;
  } catch (error) {
    executionError = error;
  }

  if (errorJson != null) {
    process.stderr.write(`${errorJson}\n`);
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
