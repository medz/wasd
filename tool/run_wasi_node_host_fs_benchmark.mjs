import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

async function main() {
  const [compiledJsPath, ...benchmarkArgs] = process.argv.slice(2);
  if (!compiledJsPath) {
    process.stderr.write(
      'usage: node tool/run_wasi_node_host_fs_benchmark.mjs <compiled.js> [benchmark args...]\n',
    );
    process.exit(2);
  }

  const resolvedScript = path.resolve(compiledJsPath);
  globalThis.self = globalThis;
  globalThis.require = createRequire(import.meta.url);

  let completeResolve;
  let completeReject;
  const complete = new Promise((resolve, reject) => {
    completeResolve = resolve;
    completeReject = reject;
  });

  globalThis.dartMainRunner = (callMain, _args) => {
    Promise.resolve(callMain(benchmarkArgs))
      .then(() => completeResolve())
      .catch((error) => completeReject(error));
  };

  await import(pathToFileURL(resolvedScript).href);
  await complete;
}

main().catch((error) => {
  const message = error?.stack ?? String(error);
  process.stderr.write(`${message}\n`);
  process.exit(1);
});
