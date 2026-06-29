import 'dart:io' as io;
import 'dart:typed_data';

import '../filesystem.dart';

/// Dart VM-backed WASI 0.3 filesystem host.
final class WASIPreview3NativeFilesystemHost
    extends WASIPreview3FilesystemHost {
  /// Creates Preview3 filesystem preopens backed by real host directories.
  ///
  /// [preopens] maps guest paths such as `/` to host directory paths.
  WASIPreview3NativeFilesystemHost({
    required Map<String, String> preopens,
    bool canMutate = false,
  }) : super(
         preopens: <String, WASIPreview3FilesystemDirectory>{
           for (final entry in preopens.entries)
             entry.key: _nativeDirectory(entry.value, canMutate: canMutate),
         },
       );
}

WASIPreview3FilesystemDirectory _nativeDirectory(
  String hostPath, {
  required bool canMutate,
}) {
  final directory = io.Directory(hostPath).absolute;
  return WASIPreview3FilesystemDirectory.dynamic(
    canMutate: canMutate,
    entries: () =>
        _listNativeDirectoryEntries(directory.path, canMutate: canMutate),
    resolveEntry: (name) => _resolveNativeDirectoryEntry(
      directory.path,
      name,
      canMutate: canMutate,
    ),
  );
}

Iterable<WASIPreview3FilesystemDirectoryEntry> _listNativeDirectoryEntries(
  String directoryPath, {
  required bool canMutate,
}) sync* {
  final directory = io.Directory(directoryPath);
  if (!directory.existsSync()) {
    return;
  }
  for (final entity in directory.listSync(followLinks: false)) {
    final entry = _nativeEntryForPath(
      _basename(entity.path),
      entity.path,
      canMutate: canMutate,
    );
    if (entry != null) {
      yield entry;
    }
  }
}

WASIPreview3FilesystemDirectoryEntry? _resolveNativeDirectoryEntry(
  String directoryPath,
  String name, {
  required bool canMutate,
}) {
  if (!_isSafeNativeChildName(name)) {
    return null;
  }
  final path = _joinNative(directoryPath, name);
  return _nativeEntryForPath(name, path, canMutate: canMutate);
}

WASIPreview3FilesystemDirectoryEntry? _nativeEntryForPath(
  String name,
  String path, {
  required bool canMutate,
}) {
  switch (io.FileSystemEntity.typeSync(path, followLinks: false)) {
    case io.FileSystemEntityType.directory:
      return WASIPreview3FilesystemDirectoryEntry.directory(
        name,
        directory: _nativeDirectory(path, canMutate: canMutate),
      );
    case io.FileSystemEntityType.file:
      return WASIPreview3FilesystemDirectoryEntry.regularFile(
        name,
        currentSize: () => BigInt.from(io.File(path).lengthSync()),
        readBytes: (offset) => _readNativeFileFrom(path, offset),
      );
    case io.FileSystemEntityType.link:
    case io.FileSystemEntityType.notFound:
    case io.FileSystemEntityType.pipe:
    case io.FileSystemEntityType.unixDomainSock:
      return null;
  }
  return null;
}

Uint8List _readNativeFileFrom(String path, BigInt offset) {
  final file = io.File(path).openSync(mode: io.FileMode.read);
  try {
    final length = file.lengthSync();
    if (offset <= BigInt.zero) {
      file.setPositionSync(0);
      return file.readSync(length);
    }
    final start = offset > BigInt.from(length) ? length : offset.toInt();
    file.setPositionSync(start);
    return file.readSync(length - start);
  } finally {
    file.closeSync();
  }
}

bool _isSafeNativeChildName(String name) {
  if (name.isEmpty || name == '.' || name == '..') {
    return false;
  }
  return !name.contains('/') && !name.contains('\\');
}

String _joinNative(String directoryPath, String name) {
  final separator = io.Platform.pathSeparator;
  if (directoryPath.endsWith(separator)) {
    return '$directoryPath$name';
  }
  return '$directoryPath$separator$name';
}

String _basename(String path) {
  final normalized = path.endsWith(io.Platform.pathSeparator)
      ? path.substring(0, path.length - io.Platform.pathSeparator.length)
      : path;
  final slash = normalized.lastIndexOf('/');
  final backslash = normalized.lastIndexOf('\\');
  final index = slash > backslash ? slash : backslash;
  return index < 0 ? normalized : normalized.substring(index + 1);
}
