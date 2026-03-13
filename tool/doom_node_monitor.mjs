import { promises as fs, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { WASI } from 'node:wasi';

const DEFAULTS = {
  wasm: 'test/fixtures/doom/doom.wasm',
  iwad: 'test/fixtures/doom/doom1.wad',
  guestRoot: '/doom',
  timedemo: '',
  frameDir: '.dart_tool/doom_node_monitor/frames',
  writeFrames: 1,
  doomWidth: 320,
  doomHeight: 200,
};

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const wasmPath = opts.wasm ?? DEFAULTS.wasm;
  const iwadPath = opts.iwad ?? DEFAULTS.iwad;
  const guestRoot = opts['guest-root'] ?? DEFAULTS.guestRoot;
  const timedemo = opts.timedemo ?? DEFAULTS.timedemo;
  const frameDir = opts['frame-dir'] ?? DEFAULTS.frameDir;
  const writeFrames = parsePositiveInt(opts['write-frames'], DEFAULTS.writeFrames);
  const mode = opts.mode ?? 'start';
  if (mode !== 'instantiate' && mode !== 'start') {
    throw new Error(`Invalid --mode value: ${mode}`);
  }

  await assertFileExists(wasmPath, 'wasm');
  await assertFileExists(iwadPath, 'IWAD');
  await fs.mkdir(frameDir, { recursive: true });
  const absoluteIwadPath = path.resolve(iwadPath);

  const wasmBytes = await fs.readFile(wasmPath);
  const monitor = new DoomMonitor({
    frameDir,
    maxFramesToWrite: writeFrames,
    stopAfterFrames: 1,
  });
  const wasi = new WASI({
    version: 'preview1',
    returnOnExit: true,
    args: [
      'doom.wasm',
      '-iwad',
      absoluteIwadPath,
      '-nosound',
      ...ifNotEmpty(timedemo, '-timedemo', timedemo),
    ],
    env: {
      HOME: guestRoot,
      TERM: 'xterm',
      DOOMWADDIR: path.dirname(absoluteIwadPath),
      DOOMWADPATH: path.dirname(absoluteIwadPath),
    },
    preopens: {
      '/': path.dirname(absoluteIwadPath),
    },
  });

  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: {
      ZwareDoomOpenWindow: (...args) => monitor.openWindow(args),
      ZwareDoomSetPalette: (...args) => monitor.setPalette(args),
      ZwareDoomRenderFrame: (...args) => monitor.renderFrame(args),
      ZwareDoomPendingEvent: (...args) => monitor.pendingEvent(args),
      ZwareDoomNextEvent: (...args) => monitor.nextEvent(args),
    },
  });

  if (instance.exports.memory instanceof WebAssembly.Memory) {
    monitor.bindMemory(instance.exports.memory);
  }

  const reportPath = path.join(frameDir, 'report.json');
  if (mode === 'instantiate') {
    await monitor.writeReport({
      reportPath,
      wasmPath,
      iwadPath,
      exitCode: 0,
      health: 'instantiated',
      mode,
    });
    console.log('DOOM NODE MONITOR PASS');
    console.log('mode=instantiate');
    console.log(`report=${reportPath}`);
    return;
  }

  let exitCode = 0;
  try {
    exitCode = wasi.start(instance) ?? 0;
  } catch (error) {
    if (error instanceof DoomStopSignal) {
      exitCode = 0;
    } else {
      throw error;
    }
  }

  await monitor.writeReport({
    reportPath,
    wasmPath,
    iwadPath,
    exitCode,
    health: monitor.health(),
    mode,
  });

  if (!monitor.isHealthy()) {
    console.error(`DOOM monitor failed: ${monitor.health()}`);
    console.error(`report=${reportPath}`);
    process.exitCode = exitCode === 0 ? 1 : exitCode;
    return;
  }

  console.log('DOOM NODE MONITOR PASS');
  console.log('mode=start');
  console.log(`frames=${monitor.frameCount}`);
  console.log(`first_frame=${monitor.writtenFrames[0]}`);
  console.log(`report=${reportPath}`);
}

class DoomMonitor {
  constructor({ frameDir, maxFramesToWrite, stopAfterFrames }) {
    this.frameDir = frameDir;
    this.maxFramesToWrite = maxFramesToWrite;
    this.stopAfterFrames = stopAfterFrames;
    this.frameCount = 0;
    this.paletteUpdates = 0;
    this.windowWidth = DEFAULTS.doomWidth;
    this.windowHeight = DEFAULTS.doomHeight;
    this.callbackTrace = [];
    this.uniqueFrameHashes = new Set();
    this.writtenFrames = [];
    this.memory = null;
    this.palette = null;
  }

  bindMemory(memory) {
    this.memory = memory;
  }

  openWindow(args) {
    this.#record('open_window', args);
    const values = args.filter(Number.isFinite).map((v) => Math.trunc(v));
    if (values.length >= 2) {
      if (isLikelyResolution(values[0], values[1])) {
        this.windowWidth = values[0];
        this.windowHeight = values[1];
      } else if (isLikelyResolution(values[1], values[0])) {
        this.windowWidth = values[1];
        this.windowHeight = values[0];
      }
    }
    return 0;
  }

  setPalette(args) {
    this.#record('set_palette', args);
    if (!this.memory || args.length === 0) {
      return 0;
    }
    const bytes = new Uint8Array(this.memory.buffer);
    const ptr = asInt(args[0]);
    if (ptr < 0 || ptr >= bytes.length) {
      return 0;
    }

    const colors = parsePositiveInt(args[1], 256);
    const paletteLength = colors * 3;
    if (ptr + paletteLength > bytes.length) {
      return 0;
    }
    this.palette = bytes.slice(ptr, ptr + paletteLength);
    this.paletteUpdates += 1;
    return 0;
  }

  renderFrame(args) {
    this.#record('render_frame', args);
    this.frameCount += 1;
    if (!this.memory) {
      return 0;
    }

    const bytes = new Uint8Array(this.memory.buffer);
    const [width, height] = this.#resolveResolution(args);
    const pixelCount = width * height;
    if (pixelCount <= 0 || pixelCount > bytes.length) {
      return 0;
    }

    const ptr = this.#resolveFramePointer(args, width, height, pixelCount, bytes.length);
    if (ptr == null) {
      return 0;
    }

    const indexed = bytes.slice(ptr, ptr + pixelCount);
    this.uniqueFrameHashes.add(fnv1a32(indexed));

    if (this.writtenFrames.length >= this.maxFramesToWrite) {
      return 0;
    }

    const rgb = this.#indexedToRgb(indexed);
    const framePath = path.join(
      this.frameDir,
      `frame_${String(this.frameCount).padStart(6, '0')}.bmp`,
    );
    writeBmp24(framePath, width, height, rgb);
    this.writtenFrames.push(framePath);
    if (this.frameCount >= this.stopAfterFrames) {
      throw new DoomStopSignal();
    }
    return 0;
  }

  pendingEvent(args) {
    this.#record('pending_event', args);
    return 0;
  }

  nextEvent(args) {
    this.#record('next_event', args);
    return 0;
  }

  health() {
    if (this.frameCount <= 0) return 'no_render_frame';
    if (this.writtenFrames.length === 0) return 'no_frame_file';
    if (this.uniqueFrameHashes.size === 0) return 'no_frame_hash';
    return 'ok';
  }

  isHealthy() {
    return this.health() === 'ok';
  }

  async writeReport({
    reportPath,
    wasmPath,
    iwadPath,
    exitCode,
    health,
    mode,
  }) {
    const report = {
      mode,
      wasm: wasmPath,
      iwad: iwadPath,
      exitCode,
      health,
      frameCount: this.frameCount,
      paletteUpdates: this.paletteUpdates,
      windowSize: {
        width: this.windowWidth,
        height: this.windowHeight,
      },
      writtenFrames: this.writtenFrames,
      uniqueFrameHashes: this.uniqueFrameHashes.size,
      callbackTrace: this.callbackTrace,
    };
    await fs.writeFile(reportPath, JSON.stringify(report));
  }

  #resolveResolution(args) {
    const values = args.filter(Number.isFinite).map((v) => Math.trunc(v));
    for (let i = 0; i + 1 < values.length; i += 1) {
      const a = values[i];
      const b = values[i + 1];
      if (isLikelyResolution(a, b)) {
        this.windowWidth = a;
        this.windowHeight = b;
        return [a, b];
      }
    }
    return [this.windowWidth, this.windowHeight];
  }

  #resolveFramePointer(args, width, height, pixelCount, memoryLength) {
    const values = args.filter(Number.isFinite).map((v) => Math.trunc(v));
    for (const value of values) {
      if (value < 0) continue;
      if (value === width || value === height) continue;
      if (value + pixelCount <= memoryLength) {
        return value;
      }
    }
    if (pixelCount <= memoryLength) {
      return 0;
    }
    return null;
  }

  #indexedToRgb(indexed) {
    const rgb = new Uint8Array(indexed.length * 3);
    if (!this.palette || this.palette.length < 3) {
      for (let i = 0; i < indexed.length; i += 1) {
        const v = indexed[i];
        const base = i * 3;
        rgb[base] = v;
        rgb[base + 1] = v;
        rgb[base + 2] = v;
      }
      return rgb;
    }
    const colorCount = Math.max(1, Math.floor(this.palette.length / 3));
    for (let i = 0; i < indexed.length; i += 1) {
      const colorIndex = indexed[i] % colorCount;
      const paletteBase = colorIndex * 3;
      const base = i * 3;
      rgb[base] = this.palette[paletteBase];
      rgb[base + 1] = this.palette[paletteBase + 1];
      rgb[base + 2] = this.palette[paletteBase + 2];
    }
    return rgb;
  }

  #record(name, args) {
    if (this.callbackTrace.length >= 24) {
      return;
    }
    this.callbackTrace.push(
      `${name}(${args.map((v) => (Number.isFinite(v) ? Math.trunc(v) : typeof v)).join(', ')})`,
    );
  }
}

class DoomStopSignal extends Error {}

async function assertFileExists(filePath, label) {
  try {
    await fs.access(filePath);
  } catch (_) {
    throw new Error(`Missing ${label} file: ${filePath}`);
  }
}

function parseArgs(args) {
  const out = {};
  for (const arg of args) {
    if (!arg.startsWith('--')) continue;
    const idx = arg.indexOf('=');
    if (idx === -1) {
      out[arg.slice(2)] = 'true';
      continue;
    }
    out[arg.slice(2, idx)] = arg.slice(idx + 1);
  }
  return out;
}

function parsePositiveInt(raw, fallback) {
  if (raw == null) return fallback;
  const n = Number.parseInt(String(raw), 10);
  if (Number.isNaN(n) || n <= 0) return fallback;
  return n;
}

function ifNotEmpty(...values) {
  if (values.length === 0) return [];
  for (const value of values) {
    if (value == null || String(value).trim().length === 0) {
      return [];
    }
  }
  return values;
}

function asInt(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  return -1;
}

function isLikelyResolution(width, height) {
  return width >= 64 && height >= 64 && width <= 4096 && height <= 4096;
}

function writeBmp24(filePath, width, height, rgb) {
  const rowStride = width * 3;
  const paddedRowStride = (rowStride + 3) & ~3;
  const pixelDataSize = paddedRowStride * height;
  const fileSize = 14 + 40 + pixelDataSize;
  const buffer = Buffer.alloc(fileSize);

  buffer.writeUInt16LE(0x4d42, 0); // BM
  buffer.writeUInt32LE(fileSize, 2);
  buffer.writeUInt32LE(54, 10);
  buffer.writeUInt32LE(40, 14); // DIB header size
  buffer.writeInt32LE(width, 18);
  buffer.writeInt32LE(height, 22);
  buffer.writeUInt16LE(1, 26); // planes
  buffer.writeUInt16LE(24, 28); // bpp
  buffer.writeUInt32LE(pixelDataSize, 34);

  let dst = 54;
  for (let y = 0; y < height; y += 1) {
    const srcRow = (height - 1 - y) * rowStride;
    for (let x = 0; x < width; x += 1) {
      const src = srcRow + x * 3;
      buffer[dst++] = rgb[src + 2];
      buffer[dst++] = rgb[src + 1];
      buffer[dst++] = rgb[src];
    }
    while ((dst - 54) % paddedRowStride !== 0) {
      buffer[dst++] = 0;
    }
  }

  writeFileSync(filePath, buffer);
}

function fnv1a32(bytes) {
  let hash = 0x811c9dc5;
  for (const byte of bytes) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

main().catch((error) => {
  const message = error?.stack ?? String(error);
  console.error(message);
  process.exitCode = 1;
});
