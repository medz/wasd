import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/async_values.dart';
import '../component/wit_adapter.dart';

/// WASI 0.3 filesystem object kind used by the Preview3 host.
enum WASIPreview3FilesystemDescriptorKind {
  /// Directory descriptor.
  directory,

  /// Regular-file descriptor.
  regularFile,
}

/// Directory contents exposed through a WASI 0.3 filesystem preopen.
final class WASIPreview3FilesystemDirectory {
  /// Creates a directory model with stable [entries].
  WASIPreview3FilesystemDirectory({
    Iterable<WASIPreview3FilesystemDirectoryEntry> entries =
        const <WASIPreview3FilesystemDirectoryEntry>[],
    this.canMutate = false,
  }) : entries = List<WASIPreview3FilesystemDirectoryEntry>.unmodifiable(
         entries,
       );

  /// Entries returned by `descriptor.read-directory`.
  final List<WASIPreview3FilesystemDirectoryEntry> entries;

  /// Whether descriptors opened for this directory can request mutation flags.
  final bool canMutate;
}

/// One directory entry exposed by [WASIPreview3FilesystemDirectory].
final class WASIPreview3FilesystemDirectoryEntry {
  /// Creates a directory entry.
  WASIPreview3FilesystemDirectoryEntry.directory(
    this.name, {
    WASIPreview3FilesystemDirectory? directory,
  }) : kind = WASIPreview3FilesystemDescriptorKind.directory,
       size = BigInt.zero,
       directory = directory ?? WASIPreview3FilesystemDirectory(),
       bytes = Uint8List(0);

  /// Creates a regular-file entry.
  WASIPreview3FilesystemDirectoryEntry.regularFile(
    this.name, {
    BigInt? size,
    List<int> bytes = const <int>[],
  }) : bytes = Uint8List.fromList(bytes),
       kind = WASIPreview3FilesystemDescriptorKind.regularFile,
       size = size ?? BigInt.from(bytes.length),
       directory = null;

  /// Entry name relative to the containing directory.
  final String name;

  /// Entry kind.
  final WASIPreview3FilesystemDescriptorKind kind;

  /// File size for regular files.
  final BigInt size;

  /// Nested directory contents for directory entries.
  final WASIPreview3FilesystemDirectory? directory;

  /// Immutable file contents for regular-file entries.
  final Uint8List bytes;
}

/// WASI 0.3 `wasi:filesystem` host imports.
final class WASIPreview3FilesystemHost {
  /// Creates a filesystem host with preopened guest directories.
  WASIPreview3FilesystemHost({
    Map<String, WASIPreview3FilesystemDirectory> preopens =
        const <String, WASIPreview3FilesystemDirectory>{},
  }) {
    for (final entry in preopens.entries) {
      final guestPath = _normalizePreopenPath(entry.key);
      final descriptor = _WASIPreview3FilesystemDescriptor.directory(
        handle: _nextHandle++,
        objectId: _nextObjectId++,
        guestPath: guestPath,
        directory: entry.value,
      );
      _descriptors[descriptor.handle] = descriptor;
      _preopens.add((descriptor.handle, guestPath));
    }
  }

  int _nextHandle = 1;
  int _nextObjectId = 1;
  final _preopens = <(int, String)>[];
  final _descriptors = <int, _WASIPreview3FilesystemDescriptor>{};

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:filesystem/preopens@0.3.0.get-directories': (_) =>
            _getDirectories(),
        'wasi:filesystem/types@0.3.0.descriptor.read-via-stream': (args) =>
            _readViaStream(_handle(args[0]), _u64(args[1])),
        'wasi:filesystem/types@0.3.0.descriptor.write-via-stream': (args) =>
            _writeViaStream(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.append-via-stream': (args) =>
            _writeViaStream(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.advise': (args) =>
            _unitResultForDescriptor(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.sync-data': (args) =>
            _unitResultForDescriptor(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.get-flags': (args) =>
            _getFlags(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.get-type': (args) =>
            _getType(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.set-size': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.set-times': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.read-directory': (args) =>
            _readDirectory(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.sync': (args) =>
            _unitResultForDescriptor(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.create-directory-at': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.stat': (args) =>
            _stat(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.stat-at': (args) =>
            _statAt(_handle(args[0]), args[2] as String),
        'wasi:filesystem/types@0.3.0.descriptor.set-times-at': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.link-at': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.open-at': (args) => _openAt(
          _handle(args[0]),
          args[2] as String,
          args[4] as WasmComponentValueData,
        ),
        'wasi:filesystem/types@0.3.0.descriptor.readlink-at': (args) =>
            _errorResult('invalid'),
        'wasi:filesystem/types@0.3.0.descriptor.remove-directory-at': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.rename-at': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.symlink-at': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.unlink-file-at': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.is-same-object': (args) =>
            _isSameObject(_handle(args[0]), _handle(args[1])),
        'wasi:filesystem/types@0.3.0.descriptor.metadata-hash': (args) =>
            _metadataHash(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.metadata-hash-at': (args) =>
            _metadataHashAt(_handle(args[0]), args[2] as String),
      });

  WasmComponentValueData _getDirectories() {
    return _list([
      for (final (handle, guestPath) in _preopens)
        _tuple(<WasmComponentValueData>[
          _integerData(handle),
          _stringData(guestPath),
        ]),
    ]);
  }

  List<Object?> _readViaStream(int handle, BigInt offset) {
    final stream = WASIComponentStream<int>('filesystem-read-$handle');
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-read-result-$handle',
    );
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      stream.writable.close();
      result.writable.complete(_errorResult('bad-descriptor'));
      return <Object?>[stream, result];
    }
    if (descriptor.kind == WASIPreview3FilesystemDescriptorKind.directory) {
      stream.writable.close();
      result.writable.complete(_errorResult('is-directory'));
      return <Object?>[stream, result];
    }
    final start = offset > BigInt.from(descriptor.bytes.length)
        ? descriptor.bytes.length
        : offset.toInt();
    stream.writable.writeAll(descriptor.bytes.sublist(start));
    stream.writable.close();
    result.writable.complete(_unitOk());
    return <Object?>[stream, result];
  }

  WASIComponentFuture<WasmComponentValueData> _writeViaStream(int handle) {
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-write-result-$handle',
    );
    result.writable.complete(_readonlyUnitResult(handle));
    return result;
  }

  WasmComponentValueData _unitResultForDescriptor(int handle) {
    if (!_descriptors.containsKey(handle)) {
      return _errorResult('bad-descriptor');
    }
    return _unitOk();
  }

  WasmComponentValueData _readonlyUnitResult(int handle) {
    if (!_descriptors.containsKey(handle)) {
      return _errorResult('bad-descriptor');
    }
    return _errorResult('read-only');
  }

  WasmComponentValueData _getFlags(int handle) {
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(
      _flagsData(<String>[
        'read',
        if (descriptor.canMutate) 'mutate-directory',
      ]),
    );
  }

  WasmComponentValueData _getType(int handle) {
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_descriptorTypeData(descriptor.kind));
  }

  List<Object?> _readDirectory(int handle) {
    final stream = WASIComponentStream<WasmComponentValueData>(
      'filesystem-directory-$handle',
    );
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-directory-result-$handle',
    );
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      stream.writable.close();
      result.writable.complete(_errorResult('bad-descriptor'));
      return <Object?>[stream, result];
    }
    if (descriptor.directory == null) {
      stream.writable.close();
      result.writable.complete(_errorResult('not-directory'));
      return <Object?>[stream, result];
    }
    for (final entry in descriptor.directory!.entries) {
      stream.writable.write(_directoryEntryData(entry));
    }
    stream.writable.close();
    result.writable.complete(_unitOk());
    return <Object?>[stream, result];
  }

  WasmComponentValueData _stat(int handle) {
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_descriptorStatData(descriptor));
  }

  WasmComponentValueData _statAt(int handle, String path) {
    final descriptor = _resolveAt(handle, path);
    if (descriptor == null) {
      return _errorResult('no-entry');
    }
    return _ok(_descriptorStatData(descriptor));
  }

  WasmComponentValueData _openAt(
    int handle,
    String path,
    WasmComponentValueData flags,
  ) {
    final base = _descriptors[handle];
    if (base == null) {
      return _errorResult('bad-descriptor');
    }
    if (_flagsContainMutation(flags) && !base.canMutate) {
      return _errorResult('read-only');
    }
    final descriptor = _resolveAt(handle, path);
    if (descriptor == null) {
      return _errorResult(
        _pathIsPermitted(path) ? 'no-entry' : 'not-permitted',
      );
    }
    final opened = descriptor.copyWithHandle(_nextHandle++);
    _descriptors[opened.handle] = opened;
    return _ok(_integerData(opened.handle));
  }

  bool _isSameObject(int left, int right) {
    final leftDescriptor = _descriptors[left];
    final rightDescriptor = _descriptors[right];
    return leftDescriptor != null &&
        rightDescriptor != null &&
        leftDescriptor.objectId == rightDescriptor.objectId;
  }

  WasmComponentValueData _metadataHash(int handle) {
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_metadataHashData(descriptor));
  }

  WasmComponentValueData _metadataHashAt(int handle, String path) {
    final descriptor = _resolveAt(handle, path);
    if (descriptor == null) {
      return _errorResult('no-entry');
    }
    return _ok(_metadataHashData(descriptor));
  }

  _WASIPreview3FilesystemDescriptor? _resolveAt(int handle, String path) {
    final base = _descriptors[handle];
    if (base?.directory == null || !_pathIsPermitted(path)) {
      return null;
    }
    if (path.isEmpty || path == '.') {
      return base;
    }
    var current = base!;
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      final directory = current.directory;
      if (directory == null) {
        return null;
      }
      final entry = directory.entries
          .where((candidate) => candidate.name == segment)
          .firstOrNull;
      if (entry == null) {
        return null;
      }
      final guestPath = '${current.guestPath}/$segment'.replaceAll('//', '/');
      current = _WASIPreview3FilesystemDescriptor.fromEntry(
        handle: _nextHandle,
        objectId: _objectIdForPath(guestPath),
        guestPath: guestPath,
        entry: entry,
      );
    }
    return current;
  }

  int _objectIdForPath(String path) {
    var hash = 0x811c9dc5;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}

final class _WASIPreview3FilesystemDescriptor {
  const _WASIPreview3FilesystemDescriptor._({
    required this.handle,
    required this.objectId,
    required this.guestPath,
    required this.kind,
    required this.size,
    required this.directory,
    required this.canMutate,
    required this.bytes,
  });

  factory _WASIPreview3FilesystemDescriptor.directory({
    required int handle,
    required int objectId,
    required String guestPath,
    required WASIPreview3FilesystemDirectory directory,
  }) {
    return _WASIPreview3FilesystemDescriptor._(
      handle: handle,
      objectId: objectId,
      guestPath: guestPath,
      kind: WASIPreview3FilesystemDescriptorKind.directory,
      size: BigInt.zero,
      directory: directory,
      canMutate: directory.canMutate,
      bytes: Uint8List(0),
    );
  }

  factory _WASIPreview3FilesystemDescriptor.fromEntry({
    required int handle,
    required int objectId,
    required String guestPath,
    required WASIPreview3FilesystemDirectoryEntry entry,
  }) {
    return _WASIPreview3FilesystemDescriptor._(
      handle: handle,
      objectId: objectId,
      guestPath: guestPath,
      kind: entry.kind,
      size: entry.size,
      directory: entry.directory,
      canMutate: entry.directory?.canMutate ?? false,
      bytes: entry.bytes,
    );
  }

  final int handle;
  final int objectId;
  final String guestPath;
  final WASIPreview3FilesystemDescriptorKind kind;
  final BigInt size;
  final WASIPreview3FilesystemDirectory? directory;
  final bool canMutate;
  final Uint8List bytes;

  _WASIPreview3FilesystemDescriptor copyWithHandle(int handle) {
    return _WASIPreview3FilesystemDescriptor._(
      handle: handle,
      objectId: objectId,
      guestPath: guestPath,
      kind: kind,
      size: size,
      directory: directory,
      canMutate: canMutate,
      bytes: bytes,
    );
  }
}

String _normalizePreopenPath(String path) {
  if (path.isEmpty) {
    return '/';
  }
  return path.startsWith('/') ? path : '/$path';
}

bool _pathIsPermitted(String path) {
  if (path.startsWith('/') || path.contains('\u0000')) {
    return false;
  }
  for (final segment in path.split('/')) {
    if (segment == '..') {
      return false;
    }
  }
  return true;
}

int _handle(Object? value) {
  return switch (value) {
    int() => value,
    BigInt() => value.toInt(),
    _ => -1,
  };
}

BigInt _u64(Object? value) {
  return switch (value) {
    BigInt() => value,
    int() => BigInt.from(value),
    _ => BigInt.zero,
  };
}

int _stableStringHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

bool _flagsContainMutation(WasmComponentValueData flags) {
  return flags.labels.contains('write') ||
      flags.labels.contains('mutate-directory');
}

WasmComponentValueData _descriptorStatData(
  _WASIPreview3FilesystemDescriptor descriptor,
) {
  return _record(<WasmComponentValueData>[
    _descriptorTypeData(descriptor.kind),
    _integerData(BigInt.one),
    _integerData(descriptor.size),
    _none(),
    _none(),
    _none(),
  ]);
}

WasmComponentValueData _directoryEntryData(
  WASIPreview3FilesystemDirectoryEntry entry,
) {
  return _record(<WasmComponentValueData>[
    _descriptorTypeData(entry.kind),
    _stringData(entry.name),
  ]);
}

WasmComponentValueData _metadataHashData(
  _WASIPreview3FilesystemDescriptor descriptor,
) {
  var lower = BigInt.from(descriptor.objectId);
  lower = (lower << 32) ^ BigInt.from(descriptor.guestPath.length);
  lower ^= descriptor.size;
  var upper = BigInt.from(descriptor.kind.index + 1);
  final directory = descriptor.directory;
  if (directory != null) {
    for (final entry in directory.entries) {
      upper ^= BigInt.from(_stableStringHash(entry.name));
      upper = (upper << 5) ^ BigInt.from(entry.kind.index + 1);
      for (final byte in entry.bytes) {
        upper = ((upper << 5) ^ BigInt.from(byte)) & _u64Mask;
      }
    }
  }
  return _record(<WasmComponentValueData>[
    _integerData(lower & _u64Mask),
    _integerData(upper & _u64Mask),
  ]);
}

WasmComponentValueData _descriptorTypeData(
  WASIPreview3FilesystemDescriptorKind kind,
) {
  return _variant(switch (kind) {
    WASIPreview3FilesystemDescriptorKind.directory => 'directory',
    WASIPreview3FilesystemDescriptorKind.regularFile => 'regular-file',
  });
}

WasmComponentValueData _ok([WasmComponentValueData? associatedValue]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _unitOk() => _ok();

WasmComponentValueData _errorResult(String code) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: _variant(code),
  );
}

WasmComponentValueData _flagsData(List<String> labels) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.flags,
    rawBytes: Uint8List(0),
    labels: labels,
  );
}

WasmComponentValueData _list(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _tuple(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _record(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _variant(
  String label, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: _variantIndex(label),
    label: label,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _none() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
}

WasmComponentValueData _stringData(String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.string,
    rawBytes: Uint8List(0),
    string: value,
  );
}

WasmComponentValueData _integerData(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

int _variantIndex(String label) {
  final index = _filesystemVariantIndexes[label];
  return index ?? 0;
}

const Map<String, int> _filesystemVariantIndexes = <String, int>{
  'block-device': 0,
  'character-device': 1,
  'directory': 2,
  'fifo': 3,
  'symbolic-link': 4,
  'regular-file': 5,
  'socket': 6,
  'other': 7,
  'access': 0,
  'already': 1,
  'bad-descriptor': 2,
  'busy': 3,
  'deadlock': 4,
  'quota': 5,
  'exist': 6,
  'file-too-large': 7,
  'illegal-byte-sequence': 8,
  'in-progress': 9,
  'interrupted': 10,
  'invalid': 11,
  'io': 12,
  'is-directory': 13,
  'loop': 14,
  'too-many-links': 15,
  'message-size': 16,
  'name-too-long': 17,
  'no-device': 18,
  'no-entry': 19,
  'no-lock': 20,
  'insufficient-memory': 21,
  'insufficient-space': 22,
  'not-directory': 23,
  'not-empty': 24,
  'not-recoverable': 25,
  'unsupported': 26,
  'no-tty': 27,
  'no-such-device': 28,
  'overflow': 29,
  'not-permitted': 30,
  'pipe': 31,
  'read-only': 32,
  'invalid-seek': 33,
  'text-file-busy': 34,
  'cross-device': 35,
};

final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;
