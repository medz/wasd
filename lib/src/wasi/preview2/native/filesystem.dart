import 'dart:io' as io;
import 'dart:typed_data';

import '../filesystem.dart';

/// Dart VM-backed WASI 0.2 filesystem host.
final class WASIPreview2NativeFilesystemHost
    extends WASIPreview2FilesystemHost {
  /// Creates Preview2 filesystem preopens backed by real host directories.
  ///
  /// [preopens] maps guest paths such as `/` to host directory paths.
  WASIPreview2NativeFilesystemHost({
    required Map<String, String> preopens,
    bool canMutate = false,
    super.streamsHost,
  }) : super(
         preopens: <String, WASIPreview2FilesystemDirectory>{
           for (final entry in preopens.entries)
             entry.key: _nativeDirectory(entry.value, canMutate: canMutate),
         },
       );
}

WASIPreview2FilesystemDirectory _nativeDirectory(
  String hostPath, {
  required bool canMutate,
}) {
  final directory = io.Directory(hostPath).absolute;
  return WASIPreview2FilesystemDirectory.dynamic(
    canMutate: canMutate,
    mutationContext: _NativeDirectoryContext(directory.path),
    metadata: () => _nativeMetadata(directory.path),
    entries: () =>
        _listNativeDirectoryEntries(directory.path, canMutate: canMutate),
    resolveEntry: (name) => _resolveNativeDirectoryEntry(
      directory.path,
      name,
      canMutate: canMutate,
    ),
    createDirectory: canMutate
        ? (name) => _createNativeDirectoryChild(directory.path, name)
        : null,
    createFile: canMutate
        ? (name) =>
              _createNativeFileChild(directory.path, name, canMutate: canMutate)
        : null,
    rename: canMutate
        ? (oldName, targetDirectory, newName) => _renameNativeChild(
            directory.path,
            oldName,
            targetDirectory,
            newName,
          )
        : null,
    symlink: canMutate
        ? (target, linkName) =>
              _symlinkNativeChild(directory.path, target, linkName)
        : null,
    readLink: (name) => _readNativeLinkChild(directory.path, name),
    setTimes: canMutate
        ? (update) => _setNativePathTimes(directory.path, update)
        : null,
    removeDirectory: canMutate
        ? (name) => _removeNativeDirectoryChild(directory.path, name)
        : null,
    unlinkFile: canMutate
        ? (name) => _unlinkNativeFileChild(directory.path, name)
        : null,
  );
}

Iterable<WASIPreview2FilesystemDirectoryEntry> _listNativeDirectoryEntries(
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

WASIPreview2FilesystemDirectoryEntry? _resolveNativeDirectoryEntry(
  String directoryPath,
  String name, {
  required bool canMutate,
}) {
  if (!_isSafeNativeChildName(name)) {
    return null;
  }
  return _nativeEntryForPath(
    name,
    _joinNative(directoryPath, name),
    canMutate: canMutate,
  );
}

WASIPreview2FilesystemDirectoryEntry? _nativeEntryForPath(
  String name,
  String path, {
  required bool canMutate,
}) {
  switch (io.FileSystemEntity.typeSync(path, followLinks: false)) {
    case io.FileSystemEntityType.directory:
      return WASIPreview2FilesystemDirectoryEntry.directory(
        name,
        directory: _nativeDirectory(path, canMutate: canMutate),
        metadata: () => _nativeMetadata(path),
      );
    case io.FileSystemEntityType.file:
      return WASIPreview2FilesystemDirectoryEntry.regularFile(
        name,
        canMutate: canMutate,
        currentSize: () => BigInt.from(io.File(path).lengthSync()),
        metadata: () => _nativeMetadata(path),
        readBytes: (offset) => _readNativeFileFrom(path, offset),
        writeBytes: canMutate
            ? (offset, bytes) => _writeNativeFileAt(path, offset, bytes)
            : null,
        setSize: canMutate ? (size) => _setNativeFileSize(path, size) : null,
        setTimes: canMutate
            ? (update) => _setNativePathTimes(path, update)
            : null,
      );
    case io.FileSystemEntityType.link:
      return WASIPreview2FilesystemDirectoryEntry.symbolicLink(
        name,
        target: io.Link(path).targetSync(),
        metadata: () => _nativeMetadata(path),
      );
    case io.FileSystemEntityType.notFound:
    case io.FileSystemEntityType.pipe:
    case io.FileSystemEntityType.unixDomainSock:
      return null;
  }
  return null;
}

WASIPreview2FilesystemMetadata _nativeMetadata(String path) {
  try {
    final stat = io.FileStat.statSync(path);
    return WASIPreview2FilesystemMetadata(
      size: BigInt.from(stat.size),
      objectIdentity: io.File(path).absolute.path,
      accessTimeNanos: _dateTimeNanos(stat.accessed),
      modificationTimeNanos: _dateTimeNanos(stat.modified),
      statusChangeTimeNanos: _dateTimeNanos(stat.changed),
    );
  } on io.FileSystemException {
    return const WASIPreview2FilesystemMetadata();
  }
}

BigInt _dateTimeNanos(DateTime value) =>
    BigInt.from(value.toUtc().microsecondsSinceEpoch) * BigInt.from(1000);

Uint8List _readNativeFileFrom(String path, BigInt offset) {
  final bytes = io.File(path).readAsBytesSync();
  final start = offset <= BigInt.zero
      ? 0
      : offset > BigInt.from(bytes.length)
      ? bytes.length
      : offset.toInt();
  return Uint8List.fromList(bytes.sublist(start));
}

WASIPreview2FilesystemDirectoryEntry? _createNativeFileChild(
  String directoryPath,
  String name, {
  required bool canMutate,
}) {
  if (!_isSafeNativeChildName(name)) {
    return null;
  }
  final path = _joinNative(directoryPath, name);
  if (io.FileSystemEntity.typeSync(path, followLinks: false) !=
      io.FileSystemEntityType.notFound) {
    return null;
  }
  try {
    io.File(path).createSync();
  } on io.FileSystemException {
    return null;
  }
  return _nativeEntryForPath(name, path, canMutate: canMutate);
}

WASIPreview2FilesystemMutationResult _createNativeDirectoryChild(
  String directoryPath,
  String name,
) {
  if (!_isSafeNativeChildName(name)) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  final path = _joinNative(directoryPath, name);
  if (io.FileSystemEntity.typeSync(path, followLinks: false) !=
      io.FileSystemEntityType.notFound) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.exist,
    );
  }
  try {
    io.Directory(path).createSync();
    return const WASIPreview2FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview2FilesystemMutationResult _renameNativeChild(
  String directoryPath,
  String oldName,
  WASIPreview2FilesystemDirectory targetDirectory,
  String newName,
) {
  if (!_isSafeNativeChildName(oldName) || !_isSafeNativeChildName(newName)) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  final targetContext = targetDirectory.mutationContext;
  if (targetContext is! _NativeDirectoryContext) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  final oldPath = _joinNative(directoryPath, oldName);
  final newPath = _joinNative(targetContext.path, newName);
  if (io.FileSystemEntity.typeSync(newPath, followLinks: false) !=
      io.FileSystemEntityType.notFound) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.exist,
    );
  }
  try {
    switch (io.FileSystemEntity.typeSync(oldPath, followLinks: false)) {
      case io.FileSystemEntityType.directory:
        io.Directory(oldPath).renameSync(newPath);
      case io.FileSystemEntityType.file:
        io.File(oldPath).renameSync(newPath);
      case io.FileSystemEntityType.link:
        io.Link(oldPath).renameSync(newPath);
      case io.FileSystemEntityType.notFound:
        return const WASIPreview2FilesystemMutationResult.error(
          WASIPreview2FilesystemMutationError.noEntry,
        );
      case io.FileSystemEntityType.pipe:
      case io.FileSystemEntityType.unixDomainSock:
        return const WASIPreview2FilesystemMutationResult.error(
          WASIPreview2FilesystemMutationError.invalid,
        );
    }
    return const WASIPreview2FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(oldPath);
  }
}

WASIPreview2FilesystemMutationResult _symlinkNativeChild(
  String directoryPath,
  String target,
  String linkName,
) {
  if (target.contains('\u0000') || !_isSafeNativeChildName(linkName)) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  final linkPath = _joinNative(directoryPath, linkName);
  if (io.FileSystemEntity.typeSync(linkPath, followLinks: false) !=
      io.FileSystemEntityType.notFound) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.exist,
    );
  }
  try {
    io.Link(linkPath).createSync(target);
    return const WASIPreview2FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(linkPath);
  }
}

WASIPreview2FilesystemReadLinkResult _readNativeLinkChild(
  String directoryPath,
  String name,
) {
  if (!_isSafeNativeChildName(name)) {
    return const WASIPreview2FilesystemReadLinkResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  final path = _joinNative(directoryPath, name);
  if (io.FileSystemEntity.typeSync(path, followLinks: false) !=
      io.FileSystemEntityType.link) {
    return const WASIPreview2FilesystemReadLinkResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  try {
    return WASIPreview2FilesystemReadLinkResult.ok(io.Link(path).targetSync());
  } on io.FileSystemException {
    return const WASIPreview2FilesystemReadLinkResult.error(
      WASIPreview2FilesystemMutationError.io,
    );
  }
}

WASIPreview2FilesystemMutationResult _removeNativeDirectoryChild(
  String directoryPath,
  String name,
) {
  if (!_isSafeNativeChildName(name)) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  final path = _joinNative(directoryPath, name);
  final directory = io.Directory(path);
  try {
    if (!directory.existsSync()) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.noEntry,
      );
    }
    if (directory.listSync(followLinks: false).isNotEmpty) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.notEmpty,
      );
    }
    directory.deleteSync();
    return const WASIPreview2FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview2FilesystemMutationResult _unlinkNativeFileChild(
  String directoryPath,
  String name,
) {
  if (!_isSafeNativeChildName(name)) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  final path = _joinNative(directoryPath, name);
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  if (type == io.FileSystemEntityType.notFound) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.noEntry,
    );
  }
  if (type == io.FileSystemEntityType.directory) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.isDirectory,
    );
  }
  try {
    io.File(path).deleteSync();
    return const WASIPreview2FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview2FilesystemMutationResult _writeNativeFileAt(
  String path,
  BigInt offset,
  Uint8List bytes,
) {
  if (offset < BigInt.zero || offset > _maxI64) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  try {
    final file = io.File(path);
    final current = file.existsSync() ? file.readAsBytesSync() : <int>[];
    final start = offset.toInt();
    final end = start + bytes.length;
    final next = Uint8List(end > current.length ? end : current.length);
    next.setAll(0, current);
    next.setRange(start, end, bytes);
    file.writeAsBytesSync(next);
    return const WASIPreview2FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview2FilesystemMutationResult _setNativeFileSize(
  String path,
  BigInt size,
) {
  if (size < BigInt.zero || size > _maxI64) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.invalid,
    );
  }
  try {
    final file = io.File(path);
    final current = file.existsSync() ? file.readAsBytesSync() : <int>[];
    final next = Uint8List(size.toInt());
    final preserved = next.length < current.length
        ? next.length
        : current.length;
    next.setRange(0, preserved, current);
    file.writeAsBytesSync(next);
    return const WASIPreview2FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview2FilesystemMutationResult _setNativePathTimes(
  String path,
  WASIPreview2FilesystemTimestampUpdate update,
) {
  if (!update.hasChanges) {
    return const WASIPreview2FilesystemMutationResult.ok();
  }
  try {
    final type = io.FileSystemEntity.typeSync(path, followLinks: false);
    if (type != io.FileSystemEntityType.file) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.unsupported,
      );
    }
    final file = io.File(path);
    final access = _dateTimeFromWasiNanos(update.accessTimeNanos);
    final modification = _dateTimeFromWasiNanos(update.modificationTimeNanos);
    if (access != null) {
      file.setLastAccessedSync(access);
    }
    if (modification != null) {
      file.setLastModifiedSync(modification);
    }
    return const WASIPreview2FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview2FilesystemMutationResult _nativeMutationFailure(String path) {
  if (!io.FileSystemEntity.isDirectorySync(io.File(path).parent.path)) {
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.noEntry,
    );
  }
  return const WASIPreview2FilesystemMutationResult.error(
    WASIPreview2FilesystemMutationError.io,
  );
}

DateTime? _dateTimeFromWasiNanos(BigInt? nanos) {
  if (nanos == null || nanos < BigInt.zero) {
    return null;
  }
  return DateTime.fromMicrosecondsSinceEpoch(
    (nanos ~/ BigInt.from(1000)).toInt(),
    isUtc: true,
  );
}

String _joinNative(String directoryPath, String name) {
  if (directoryPath.endsWith(io.Platform.pathSeparator)) {
    return '$directoryPath$name';
  }
  return '$directoryPath${io.Platform.pathSeparator}$name';
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}

bool _isSafeNativeChildName(String name) {
  return name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\\') &&
      !name.contains('\u0000');
}

final class _NativeDirectoryContext {
  const _NativeDirectoryContext(this.path);

  final String path;
}

final BigInt _maxI64 = (BigInt.one << 63) - BigInt.one;
