import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

Future<void> main(List<String> args) async {
  late final _RunnerOptions options;
  try {
    options = _RunnerOptions.parse(args);
  } on Object catch (error) {
    io.stderr
      ..writeln('wasd-preview3-runner: $error')
      ..writeln(_usage);
    io.exitCode = 2;
    return;
  }

  if (options.showHelp) {
    io.stdout.writeln(_usage);
    return;
  }
  if (options.showVersion) {
    io.stdout.writeln('wasd-preview3-runner local');
    return;
  }

  final componentPath = options.componentPath;
  if (componentPath == null) {
    io.stderr.writeln(_usage);
    io.exitCode = 2;
    return;
  }

  final stdin = WASIComponentStream<int>('testsuite-stdin');
  final stdinSubscription = pumpPreview3Stdin(io.stdin, stdin.writable);
  try {
    await withPreparedPreview3Preopens(
      directPreopens: <String, String>{
        for (final dir in options.dirs) dir.guestPath: dir.hostPath,
      },
      copiedPreopens: <String, String>{
        for (final dir in options.copyDirs) dir.guestPath: dir.hostPath,
      },
      run: (preopens) async {
        final component = WasmComponent.decode(
          await io.File(componentPath).readAsBytes(),
        );
        final validationErrors = component.validate();
        if (validationErrors.isNotEmpty) {
          io.stderr.writeln('wasd-preview3-runner validation failed:');
          for (final error in validationErrors) {
            io.stderr.writeln('- $error');
          }
          io.exitCode = 1;
          return;
        }

        final host = WASIPreview3ComponentHost.native(
          args: <String>[_basename(componentPath), ...options.programArgs],
          env: options.env,
          stdin: stdin.readable,
          preopens: preopens,
          canMutatePreopens: true,
          stdout: (bytes) {
            io.stdout.add(bytes);
            unawaited(io.stdout.flush());
          },
          stderr: (bytes) {
            io.stderr.add(bytes);
            unawaited(io.stderr.flush());
          },
        );
        final plan = host.prepareComponent(component);
        if (!plan.canBindWithAdapters) {
          io.stderr.writeln('wasd-preview3-runner bind preflight failed:');
          for (final error in plan.versionErrors) {
            io.stderr.writeln('- $error');
          }
          for (final error in plan.validationErrors) {
            io.stderr.writeln('- $error');
          }
          for (final error in plan.unsupportedDefinitions) {
            io.stderr.writeln('- $error');
          }
          for (final error in plan.bindingErrors) {
            io.stderr.writeln('- $error');
          }
          io.exitCode = 1;
          return;
        }

        switch (options.world) {
          case 'wasi:cli/command':
            final result = await runPreview3CommandWithBufferedOutput(
              host,
              component,
              flushCompatibilityOutput: false,
            );
            io.exitCode = result.exitCode;
          case 'wasi:http/service':
            final runner = WASIPreview3ServiceRunner(host);
            final server = await startPreview3HttpServiceServer(
              (request) => runner.handle(component, request),
            );
            io.stderr.writeln('http://127.0.0.1:${server.port}');
            await io.stderr.flush();
            await _serveUntilInterrupted(server);
            io.exitCode = 0;
        }
      },
    );
  } on Object catch (error, stackTrace) {
    io.stderr
      ..writeln('wasd-preview3-runner failed: $error')
      ..writeln(stackTrace);
    io.exitCode = 1;
  } finally {
    await stdinSubscription.cancel();
    if (!stdin.writable.isClosed) {
      stdin.writable.close();
    }
  }
}

/// Handles one Preview3 service request.
typedef Preview3HttpServiceHandler =
    Future<WASIPreview3HttpResult<WASIPreview3HttpResponse>> Function(
      WASIPreview3HttpRequest request,
    );

/// Starts the loopback HTTP bridge expected by the official WASI testsuite.
Future<io.HttpServer> startPreview3HttpServiceServer(
  Preview3HttpServiceHandler handler, {
  io.InternetAddress? address,
  int port = 0,
}) async {
  final server = await io.HttpServer.bind(
    address ?? io.InternetAddress.loopbackIPv4,
    port,
  );
  server.listen((request) {
    unawaited(_handlePreview3HttpRequest(request, handler));
  });
  return server;
}

Future<void> _serveUntilInterrupted(io.HttpServer server) async {
  final interrupted = Completer<void>();
  final signals = io.ProcessSignal.sigint.watch().listen((_) {
    if (!interrupted.isCompleted) {
      interrupted.complete();
    }
  });
  try {
    await interrupted.future;
  } finally {
    await signals.cancel();
    await server.close(force: true);
  }
}

Future<void> _handlePreview3HttpRequest(
  io.HttpRequest request,
  Preview3HttpServiceHandler handler,
) async {
  final body = WASIComponentStream<int>('testsuite-http-request-body');
  final bodySubscription = request.listen(
    (bytes) {
      if (!body.writable.isClosed &&
          !body.writable.isCancelled &&
          !body.writable.isDropped) {
        body.writable.writeAll(bytes);
      }
    },
    onDone: () {
      if (!body.writable.isClosed) {
        body.writable.close();
      }
    },
    onError: (Object _, StackTrace _) {
      if (!body.writable.isClosed) {
        body.writable.cancel();
      }
    },
    cancelOnError: true,
  );

  try {
    final wasiRequest =
        WASIPreview3HttpRequest.noTrailers(
            headers: WASIPreview3HttpFields(entries: _requestHeaders(request)),
            contents: body,
          )
          ..method = _requestMethod(request.method)
          ..pathWithQuery = request.uri.toString()
          ..scheme = const WASIPreview3HttpScheme.standard('HTTP')
          ..authority = request.requestedUri.authority;
    final result = await handler(wasiRequest);
    if (!result.isOk) {
      request.response.statusCode = io.HttpStatus.internalServerError;
      await request.response.close();
      return;
    }
    await _writePreview3HttpResponse(request.response, result.value!);
  } on Object catch (error, stackTrace) {
    io.stderr
      ..writeln('wasd-preview3-runner request failed: $error')
      ..writeln(stackTrace);
    try {
      request.response.statusCode = io.HttpStatus.internalServerError;
      await request.response.close();
    } on Object {
      // The response may already be committed or disconnected.
    }
  } finally {
    await bodySubscription.cancel();
    if (!body.writable.isClosed) {
      body.writable.close();
    }
  }
}

Future<void> _writePreview3HttpResponse(
  io.HttpResponse output,
  WASIPreview3HttpResponse response,
) async {
  output.statusCode = response.statusCode;
  for (final entry in response.headers.entries) {
    output.headers.add(entry.name, latin1.decode(entry.value));
  }
  final contents = response.contents;
  if (contents != null) {
    while (true) {
      final bytes = await contents.readable.readWhenAvailable(64 * 1024);
      if (bytes.isEmpty) {
        break;
      }
      output.add(bytes);
    }
  }
  await output.close();
  response.completeTransmission(const WASIPreview3HttpResult<void>.ok(null));
}

List<WASIPreview3HttpFieldEntry> _requestHeaders(io.HttpRequest request) {
  final entries = <WASIPreview3HttpFieldEntry>[];
  request.headers.forEach((name, values) {
    for (final value in values) {
      entries.add(WASIPreview3HttpFieldEntry(name, latin1.encode(value)));
    }
  });
  return entries;
}

WASIPreview3HttpMethod _requestMethod(String method) {
  final normalized = method.toLowerCase();
  return switch (normalized) {
    'get' ||
    'head' ||
    'post' ||
    'put' ||
    'delete' ||
    'connect' ||
    'options' ||
    'trace' ||
    'patch' => WASIPreview3HttpMethod.standard(normalized),
    _ => WASIPreview3HttpMethod.other(method),
  };
}

/// Pumps [source] bytes into Preview3 [writable] until EOF.
StreamSubscription<List<int>> pumpPreview3Stdin(
  Stream<List<int>> source,
  WASIComponentWritableStream<int> writable,
) {
  return source.listen(
    (bytes) {
      if (!writable.isClosed && !writable.isCancelled && !writable.isDropped) {
        writable.writeAll(bytes);
      }
    },
    onDone: () {
      if (!writable.isClosed) {
        writable.close();
      }
    },
    onError: (Object _, StackTrace _) {
      if (!writable.isClosed) {
        writable.close();
      }
    },
    cancelOnError: true,
  );
}

/// Runs [run] with direct and isolated-copy Preview3 preopens.
Future<T> withPreparedPreview3Preopens<T>({
  required Map<String, String> directPreopens,
  required Map<String, String> copiedPreopens,
  required Future<T> Function(Map<String, String> preopens) run,
}) async {
  final temporaryDirectories = <io.Directory>[];
  try {
    final preopens = <String, String>{...directPreopens};
    for (final entry in copiedPreopens.entries) {
      final temporary = await io.Directory.systemTemp.createTemp(
        'wasd-wasip3-preopen-',
      );
      temporaryDirectories.add(temporary);
      await _copyDirectoryContents(io.Directory(entry.value), temporary);
      preopens[entry.key] = temporary.path;
    }
    return await run(Map<String, String>.unmodifiable(preopens));
  } finally {
    for (final directory in temporaryDirectories.reversed) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }
}

Future<void> _copyDirectoryContents(
  io.Directory source,
  io.Directory destination,
) async {
  await for (final entity in source.list(followLinks: false)) {
    final name = _basename(entity.path);
    final targetPath = '${destination.path}${io.Platform.pathSeparator}$name';
    final type = await io.FileSystemEntity.type(
      entity.path,
      followLinks: false,
    );
    switch (type) {
      case io.FileSystemEntityType.file:
        await io.File(entity.path).copy(targetPath);
      case io.FileSystemEntityType.directory:
        final target = await io.Directory(targetPath).create();
        await _copyDirectoryContents(io.Directory(entity.path), target);
      case io.FileSystemEntityType.link:
        await io.Link(targetPath).create(await io.Link(entity.path).target());
      case io.FileSystemEntityType.notFound:
        throw io.FileSystemException(
          'preopen entry disappeared while copying',
          entity.path,
        );
      case io.FileSystemEntityType.pipe:
      case io.FileSystemEntityType.unixDomainSock:
        throw io.FileSystemException(
          'unsupported preopen entry type: $type',
          entity.path,
        );
    }
  }
}

/// Runs a Preview3 command and flushes output written through Preview2 adapters.
Future<WASIPreview3CommandResult> runPreview3CommandWithBufferedOutput(
  WASIPreview3ComponentHost host,
  WasmComponent component, {
  io.IOSink? stdout,
  io.IOSink? stderr,
  bool flushCompatibilityOutput = true,
}) async {
  final output = stdout ?? io.stdout;
  final errorOutput = stderr ?? io.stderr;
  try {
    return await WASIPreview3CommandRunner(host).run(component);
  } finally {
    if (flushCompatibilityOutput) {
      final compatibilityCli = host.preview2CompatibilityHost.cliHost;
      output.add(compatibilityCli.stdoutBytes);
      errorOutput.add(compatibilityCli.stderrBytes);
    }
    await Future.wait(<Future<void>>[output.flush(), errorOutput.flush()]);
  }
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

final class _PreopenDir {
  const _PreopenDir({required this.hostPath, required this.guestPath});

  final String hostPath;
  final String guestPath;

  static _PreopenDir parse(String value) {
    final separator = value.indexOf('::');
    if (separator <= 0 || separator + 2 >= value.length) {
      throw ArgumentError.value(value, 'dir', 'expected HOST::GUEST');
    }
    return _PreopenDir(
      hostPath: value.substring(0, separator),
      guestPath: value.substring(separator + 2),
    );
  }
}

final class _RunnerOptions {
  const _RunnerOptions({
    required this.showHelp,
    required this.showVersion,
    required this.world,
    required this.proposals,
    required this.env,
    required this.dirs,
    required this.copyDirs,
    required this.componentPath,
    required this.programArgs,
  });

  final bool showHelp;
  final bool showVersion;
  final String world;
  final List<String> proposals;
  final Map<String, String> env;
  final List<_PreopenDir> dirs;
  final List<_PreopenDir> copyDirs;
  final String? componentPath;
  final List<String> programArgs;

  static _RunnerOptions parse(List<String> args) {
    var showHelp = false;
    var showVersion = false;
    var world = 'wasi:cli/command';
    final proposals = <String>[];
    final env = <String, String>{};
    final dirs = <_PreopenDir>[];
    final copyDirs = <_PreopenDir>[];
    String? componentPath;
    final programArgs = <String>[];

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (componentPath != null) {
        programArgs.add(arg);
        continue;
      }

      switch (arg) {
        case '--help':
        case '-h':
          showHelp = true;
        case '--version':
          showVersion = true;
        case '--world':
          world = _readOptionValue(args, ++index, '--world');
        case '--proposal':
          proposals.add(_readOptionValue(args, ++index, '--proposal'));
        case '--env':
          final value = _readOptionValue(args, ++index, '--env');
          final separator = value.indexOf('=');
          if (separator <= 0) {
            throw ArgumentError.value(value, '--env', 'expected KEY=VALUE');
          }
          env[value.substring(0, separator)] = value.substring(separator + 1);
        case '--dir':
          dirs.add(_PreopenDir.parse(_readOptionValue(args, ++index, '--dir')));
        case '--copy-dir':
          copyDirs.add(
            _PreopenDir.parse(_readOptionValue(args, ++index, '--copy-dir')),
          );
        case '--':
          if (index + 1 >= args.length) {
            throw ArgumentError('-- requires a component path');
          }
          componentPath = args[++index];
        default:
          if (arg.startsWith('--world=')) {
            world = arg.substring('--world='.length);
          } else if (arg.startsWith('--proposal=')) {
            proposals.add(arg.substring('--proposal='.length));
          } else if (arg.startsWith('--env=')) {
            final value = arg.substring('--env='.length);
            final separator = value.indexOf('=');
            if (separator <= 0) {
              throw ArgumentError.value(value, '--env', 'expected KEY=VALUE');
            }
            env[value.substring(0, separator)] = value.substring(separator + 1);
          } else if (arg.startsWith('--dir=')) {
            dirs.add(_PreopenDir.parse(arg.substring('--dir='.length)));
          } else if (arg.startsWith('--copy-dir=')) {
            copyDirs.add(
              _PreopenDir.parse(arg.substring('--copy-dir='.length)),
            );
          } else if (arg.startsWith('-')) {
            throw ArgumentError('unknown option: $arg');
          } else {
            componentPath = arg;
          }
      }
    }

    if (world != 'wasi:cli/command' && world != 'wasi:http/service') {
      throw ArgumentError.value(world, '--world', 'unsupported WASI world');
    }

    return _RunnerOptions(
      showHelp: showHelp,
      showVersion: showVersion,
      world: world,
      proposals: List<String>.unmodifiable(proposals),
      env: Map<String, String>.unmodifiable(env),
      dirs: List<_PreopenDir>.unmodifiable(dirs),
      copyDirs: List<_PreopenDir>.unmodifiable(copyDirs),
      componentPath: componentPath,
      programArgs: List<String>.unmodifiable(programArgs),
    );
  }

  static String _readOptionValue(List<String> args, int index, String option) {
    if (index >= args.length) {
      throw ArgumentError('$option requires a value');
    }
    return args[index];
  }
}

const String _usage = '''
Usage: dart run tool/wasi_testsuite_preview3_component_runner.dart [options] <component.wasm> [args...]

Options:
  --world WORLD         Select wasi:cli/command or wasi:http/service.
  --proposal NAME       Record an enabled official testsuite proposal.
  --env KEY=VALUE       Add a WASI environment variable.
  --dir HOST::GUEST     Map HOST files into the GUEST preopen.
  --copy-dir HOST::GUEST
                        Copy HOST into a temporary GUEST preopen.
  --version             Print runner version.
  -h, --help            Show this help.
''';
