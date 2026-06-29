import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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
    link: canMutate
        ? (oldName, targetDirectory, newName) => _linkNativeChild(
            directory.path,
            oldName,
            targetDirectory,
            newName,
          )
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
        metadata: () => _nativeMetadata(path),
      );
    case io.FileSystemEntityType.file:
      return WASIPreview3FilesystemDirectoryEntry.regularFile(
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
      return WASIPreview3FilesystemDirectoryEntry.symbolicLink(
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

WASIPreview3FilesystemMetadata _nativeMetadata(String path) {
  try {
    final stat = io.FileStat.statSync(path);
    return WASIPreview3FilesystemMetadata(
      size: BigInt.from(stat.size),
      accessTimeNanos: _dateTimeNanos(stat.accessed),
      modificationTimeNanos: _dateTimeNanos(stat.modified),
      statusChangeTimeNanos: _dateTimeNanos(stat.changed),
    );
  } on io.FileSystemException {
    return const WASIPreview3FilesystemMetadata();
  }
}

BigInt _dateTimeNanos(DateTime value) =>
    BigInt.from(value.toUtc().microsecondsSinceEpoch) * BigInt.from(1000);

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

WASIPreview3FilesystemMutationResult _linkNativeChild(
  String directoryPath,
  String oldName,
  WASIPreview3FilesystemDirectory targetDirectory,
  String newName,
) {
  if (!_isSafeNativeChildName(oldName) || !_isSafeNativeChildName(newName)) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final targetContext = _nativeDirectoryContext(targetDirectory);
  if (targetContext == null) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final oldPath = _joinNative(directoryPath, oldName);
  final newPath = _joinNative(targetContext.path, newName);
  final oldType = io.FileSystemEntity.typeSync(oldPath, followLinks: false);
  if (oldType == io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.noEntry,
    );
  }
  if (oldType == io.FileSystemEntityType.directory) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.isDirectory,
    );
  }
  if (io.FileSystemEntity.typeSync(newPath, followLinks: false) !=
      io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.exist,
    );
  }
  try {
    if (!_nativeHardLink(oldPath, newPath)) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.io,
      );
    }
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(newPath);
  }
}

WASIPreview3FilesystemMutationResult _renameNativeChild(
  String directoryPath,
  String oldName,
  WASIPreview3FilesystemDirectory targetDirectory,
  String newName,
) {
  if (!_isSafeNativeChildName(oldName) || !_isSafeNativeChildName(newName)) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final targetContext = _nativeDirectoryContext(targetDirectory);
  if (targetContext == null) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final oldPath = _joinNative(directoryPath, oldName);
  final newPath = _joinNative(targetContext.path, newName);
  final oldType = io.FileSystemEntity.typeSync(oldPath, followLinks: false);
  if (oldType == io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.noEntry,
    );
  }
  if (io.FileSystemEntity.typeSync(newPath, followLinks: false) !=
      io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.exist,
    );
  }
  try {
    switch (oldType) {
      case io.FileSystemEntityType.directory:
        io.Directory(oldPath).renameSync(newPath);
      case io.FileSystemEntityType.link:
        io.Link(oldPath).renameSync(newPath);
      case io.FileSystemEntityType.file:
        io.File(oldPath).renameSync(newPath);
      case io.FileSystemEntityType.pipe:
      case io.FileSystemEntityType.unixDomainSock:
      case io.FileSystemEntityType.notFound:
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.invalid,
        );
    }
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(oldPath);
  }
}

WASIPreview3FilesystemMutationResult _symlinkNativeChild(
  String directoryPath,
  String target,
  String linkName,
) {
  if (target.contains('\u0000') || !_isSafeNativeChildName(linkName)) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final linkPath = _joinNative(directoryPath, linkName);
  if (io.FileSystemEntity.typeSync(linkPath, followLinks: false) !=
      io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.exist,
    );
  }
  try {
    io.Link(linkPath).createSync(target);
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(linkPath);
  }
}

WASIPreview3FilesystemReadLinkResult _readNativeLinkChild(
  String directoryPath,
  String name,
) {
  if (!_isSafeNativeChildName(name)) {
    return const WASIPreview3FilesystemReadLinkResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final path = _joinNative(directoryPath, name);
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  if (type == io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemReadLinkResult.error(
      WASIPreview3FilesystemMutationError.noEntry,
    );
  }
  if (type != io.FileSystemEntityType.link) {
    return const WASIPreview3FilesystemReadLinkResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  try {
    return WASIPreview3FilesystemReadLinkResult.ok(io.Link(path).targetSync());
  } on io.FileSystemException {
    return const WASIPreview3FilesystemReadLinkResult.error(
      WASIPreview3FilesystemMutationError.io,
    );
  }
}

WASIPreview3FilesystemDirectoryEntry? _createNativeFileChild(
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

WASIPreview3FilesystemMutationResult _createNativeDirectoryChild(
  String directoryPath,
  String name,
) {
  if (!_isSafeNativeChildName(name)) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final path = _joinNative(directoryPath, name);
  if (io.FileSystemEntity.typeSync(path, followLinks: false) !=
      io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.exist,
    );
  }
  try {
    io.Directory(path).createSync();
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview3FilesystemMutationResult _removeNativeDirectoryChild(
  String directoryPath,
  String name,
) {
  if (!_isSafeNativeChildName(name)) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final path = _joinNative(directoryPath, name);
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  if (type == io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.noEntry,
    );
  }
  if (type != io.FileSystemEntityType.directory) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.notDirectory,
    );
  }
  final directory = io.Directory(path);
  try {
    if (directory.listSync(followLinks: false).isNotEmpty) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.notEmpty,
      );
    }
    directory.deleteSync();
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview3FilesystemMutationResult _unlinkNativeFileChild(
  String directoryPath,
  String name,
) {
  if (!_isSafeNativeChildName(name)) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final path = _joinNative(directoryPath, name);
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  if (type == io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.noEntry,
    );
  }
  if (type == io.FileSystemEntityType.directory) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.isDirectory,
    );
  }
  try {
    io.File(path).deleteSync();
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview3FilesystemMutationResult _writeNativeFileAt(
  String path,
  BigInt offset,
  Uint8List bytes,
) {
  if (offset < BigInt.zero || offset > _maxI64) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  if (type == io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.noEntry,
    );
  }
  if (type == io.FileSystemEntityType.directory) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.isDirectory,
    );
  }
  if (bytes.isEmpty) {
    return const WASIPreview3FilesystemMutationResult.ok();
  }
  if (!io.Platform.isWindows) {
    return _posixWriteNativeFileAt(path, offset.toInt(), bytes);
  }
  return _rewriteNativeFileAt(path, offset.toInt(), bytes);
}

WASIPreview3FilesystemMutationResult _setNativeFileSize(
  String path,
  BigInt size,
) {
  if (size < BigInt.zero || size > _maxI64) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  if (type == io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.noEntry,
    );
  }
  if (type == io.FileSystemEntityType.directory) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.isDirectory,
    );
  }
  if (!io.Platform.isWindows) {
    return _posixSetNativeFileSize(path, size.toInt());
  }
  return _rewriteNativeFileSize(path, size.toInt());
}

WASIPreview3FilesystemMutationResult _setNativePathTimes(
  String path,
  WASIPreview3FilesystemTimestampUpdate update,
) {
  if (!update.hasChanges) {
    return const WASIPreview3FilesystemMutationResult.ok();
  }
  final accessTime = _dateTimeFromWasiNanos(update.accessTimeNanos);
  final modificationTime = _dateTimeFromWasiNanos(update.modificationTimeNanos);
  if ((update.accessTimeNanos != null && accessTime == null) ||
      (update.modificationTimeNanos != null && modificationTime == null)) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  try {
    switch (type) {
      case io.FileSystemEntityType.file:
        if (!io.Platform.isWindows) {
          return _posixSetNativePathTimes(path, accessTime, modificationTime);
        }
        final file = io.File(path);
        if (accessTime != null) {
          file.setLastAccessedSync(accessTime);
        }
        if (modificationTime != null) {
          file.setLastModifiedSync(modificationTime);
        }
      case io.FileSystemEntityType.directory:
        if (!io.Platform.isWindows) {
          return _posixSetNativePathTimes(path, accessTime, modificationTime);
        }
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.unsupported,
        );
      case io.FileSystemEntityType.link:
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.unsupported,
        );
      case io.FileSystemEntityType.notFound:
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.noEntry,
        );
      case io.FileSystemEntityType.pipe:
      case io.FileSystemEntityType.unixDomainSock:
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.invalid,
        );
    }
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  } on ArgumentError {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.invalid,
    );
  }
}

WASIPreview3FilesystemMutationResult _posixSetNativePathTimes(
  String path,
  DateTime? accessTime,
  DateTime? modificationTime,
) {
  final stat = io.FileStat.statSync(path);
  final effectiveAccessTime = accessTime ?? stat.accessed;
  final effectiveModificationTime = modificationTime ?? stat.modified;
  final pathPointer = path.toNativeUtf8();
  final times = calloc<_PosixTimeval>(2);
  try {
    _writePosixTimeval(times, 0, effectiveAccessTime);
    _writePosixTimeval(times, 1, effectiveModificationTime);
    if (_posixUtimesFunction()(pathPointer, times) != 0) {
      if (io.FileSystemEntity.typeSync(path, followLinks: false) ==
          io.FileSystemEntityType.notFound) {
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.noEntry,
        );
      }
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.io,
      );
    }
    return const WASIPreview3FilesystemMutationResult.ok();
  } catch (_) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.io,
    );
  } finally {
    calloc.free(times);
    malloc.free(pathPointer);
  }
}

void _writePosixTimeval(
  ffi.Pointer<_PosixTimeval> times,
  int index,
  DateTime value,
) {
  final microseconds = value.toUtc().microsecondsSinceEpoch;
  times[index].tvSec = microseconds ~/ 1000000;
  times[index].tvUsec = microseconds.remainder(1000000);
}

DateTime? _dateTimeFromWasiNanos(BigInt? nanos) {
  if (nanos == null) {
    return null;
  }
  if (nanos < BigInt.zero || nanos > _maxI64) {
    return null;
  }
  try {
    final microseconds = (nanos ~/ BigInt.from(1000)).toInt();
    return DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
  } on ArgumentError {
    return null;
  } on UnsupportedError {
    return null;
  }
}

WASIPreview3FilesystemMutationResult _posixWriteNativeFileAt(
  String path,
  int offset,
  Uint8List bytes,
) {
  final pathPointer = path.toNativeUtf8();
  final dataPointer = malloc<ffi.Uint8>(bytes.length);
  try {
    dataPointer.asTypedList(bytes.length).setAll(0, bytes);
    final fd = _posixOpenFunction()(pathPointer, _posixOpenWriteOnly, 0);
    if (fd < 0) {
      return _nativeMutationFailure(path);
    }
    try {
      var writtenTotal = 0;
      while (writtenTotal < bytes.length) {
        final written = _posixPwriteFunction()(
          fd,
          (dataPointer + writtenTotal).cast<ffi.Void>(),
          bytes.length - writtenTotal,
          offset + writtenTotal,
        );
        if (written <= 0) {
          return const WASIPreview3FilesystemMutationResult.error(
            WASIPreview3FilesystemMutationError.io,
          );
        }
        writtenTotal += written;
      }
      return const WASIPreview3FilesystemMutationResult.ok();
    } finally {
      _posixCloseFunction()(fd);
    }
  } catch (_) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.io,
    );
  } finally {
    malloc.free(dataPointer);
    malloc.free(pathPointer);
  }
}

WASIPreview3FilesystemMutationResult _posixSetNativeFileSize(
  String path,
  int size,
) {
  final pathPointer = path.toNativeUtf8();
  try {
    final fd = _posixOpenFunction()(pathPointer, _posixOpenWriteOnly, 0);
    if (fd < 0) {
      return _nativeMutationFailure(path);
    }
    try {
      if (_posixFtruncateFunction()(fd, size) != 0) {
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.io,
        );
      }
      return const WASIPreview3FilesystemMutationResult.ok();
    } finally {
      _posixCloseFunction()(fd);
    }
  } catch (_) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.io,
    );
  } finally {
    malloc.free(pathPointer);
  }
}

WASIPreview3FilesystemMutationResult _rewriteNativeFileAt(
  String path,
  int offset,
  Uint8List bytes,
) {
  try {
    final file = io.File(path);
    final existing = file.existsSync() ? file.readAsBytesSync() : Uint8List(0);
    final nextLength = offset + bytes.length > existing.length
        ? offset + bytes.length
        : existing.length;
    final next = Uint8List(nextLength);
    next.setAll(0, existing);
    next.setRange(offset, offset + bytes.length, bytes);
    file.writeAsBytesSync(next, flush: true);
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview3FilesystemMutationResult _rewriteNativeFileSize(
  String path,
  int size,
) {
  try {
    final file = io.File(path);
    final existing = file.existsSync() ? file.readAsBytesSync() : Uint8List(0);
    final next = Uint8List(size);
    final preserved = size < existing.length ? size : existing.length;
    next.setRange(0, preserved, existing);
    file.writeAsBytesSync(next, flush: true);
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException {
    return _nativeMutationFailure(path);
  }
}

WASIPreview3FilesystemMutationResult _nativeMutationFailure(String path) {
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  return switch (type) {
    io.FileSystemEntityType.notFound =>
      const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.noEntry,
      ),
    io.FileSystemEntityType.directory =>
      const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.isDirectory,
      ),
    _ => const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.io,
    ),
  };
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

_NativeDirectoryContext? _nativeDirectoryContext(
  WASIPreview3FilesystemDirectory directory,
) {
  final context = directory.mutationContext;
  return context is _NativeDirectoryContext ? context : null;
}

bool _nativeHardLink(String existingPath, String newPath) {
  if (io.Platform.isWindows) {
    return _windowsCreateHardLink(existingPath, newPath);
  }
  return _posixCreateHardLink(existingPath, newPath);
}

bool _posixCreateHardLink(String existingPath, String newPath) {
  final existingPathPointer = existingPath.toNativeUtf8();
  final newPathPointer = newPath.toNativeUtf8();
  try {
    return _posixLinkFunction()(existingPathPointer, newPathPointer) == 0;
  } finally {
    malloc.free(existingPathPointer);
    malloc.free(newPathPointer);
  }
}

bool _windowsCreateHardLink(String existingPath, String newPath) {
  final createHardLink = _windowsCreateHardLinkFunction();
  final newPathPointer = newPath.toNativeUtf16();
  final existingPathPointer = existingPath.toNativeUtf16();
  try {
    return createHardLink(newPathPointer, existingPathPointer, ffi.nullptr) !=
        0;
  } finally {
    malloc.free(newPathPointer);
    malloc.free(existingPathPointer);
  }
}

ffi.DynamicLibrary _openPosixCLibrary() {
  if (io.Platform.isLinux) {
    return ffi.DynamicLibrary.open('libc.so.6');
  }
  if (io.Platform.isAndroid) {
    return ffi.DynamicLibrary.open('libc.so');
  }
  return ffi.DynamicLibrary.process();
}

_PosixOpenDart? _cachedPosixOpen;
_PosixPwriteDart? _cachedPosixPwrite;
_PosixFtruncateDart? _cachedPosixFtruncate;
_PosixCloseDart? _cachedPosixClose;
_PosixLinkDart? _cachedPosixLink;
_PosixUtimesDart? _cachedPosixUtimes;
_WindowsCreateHardLinkDart? _cachedWindowsCreateHardLink;

_PosixOpenDart _posixOpenFunction() => _cachedPosixOpen ??= _openPosixCLibrary()
    .lookupFunction<_PosixOpenNative, _PosixOpenDart>('open');

_PosixPwriteDart _posixPwriteFunction() =>
    _cachedPosixPwrite ??= _openPosixCLibrary()
        .lookupFunction<_PosixPwriteNative, _PosixPwriteDart>('pwrite');

_PosixFtruncateDart _posixFtruncateFunction() =>
    _cachedPosixFtruncate ??= _openPosixCLibrary()
        .lookupFunction<_PosixFtruncateNative, _PosixFtruncateDart>(
          'ftruncate',
        );

_PosixCloseDart _posixCloseFunction() =>
    _cachedPosixClose ??= _openPosixCLibrary()
        .lookupFunction<_PosixCloseNative, _PosixCloseDart>('close');

_PosixLinkDart _posixLinkFunction() => _cachedPosixLink ??= _openPosixCLibrary()
    .lookupFunction<_PosixLinkNative, _PosixLinkDart>('link');

_PosixUtimesDart _posixUtimesFunction() =>
    _cachedPosixUtimes ??= _openPosixCLibrary()
        .lookupFunction<_PosixUtimesNative, _PosixUtimesDart>('utimes');

_WindowsCreateHardLinkDart _windowsCreateHardLinkFunction() =>
    _cachedWindowsCreateHardLink ??= ffi.DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          _WindowsCreateHardLinkNative,
          _WindowsCreateHardLinkDart
        >('CreateHardLinkW');

typedef _PosixOpenNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Int32, ffi.Uint32);
typedef _PosixOpenDart = int Function(ffi.Pointer<Utf8>, int, int);

typedef _PosixPwriteNative =
    ffi.IntPtr Function(
      ffi.Int32,
      ffi.Pointer<ffi.Void>,
      ffi.Uint64,
      ffi.Int64,
    );
typedef _PosixPwriteDart = int Function(int, ffi.Pointer<ffi.Void>, int, int);

typedef _PosixFtruncateNative = ffi.Int32 Function(ffi.Int32, ffi.Int64);
typedef _PosixFtruncateDart = int Function(int, int);

typedef _PosixCloseNative = ffi.Int32 Function(ffi.Int32);
typedef _PosixCloseDart = int Function(int);

typedef _PosixLinkNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _PosixLinkDart = int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

typedef _PosixUtimesNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<_PosixTimeval>);
typedef _PosixUtimesDart =
    int Function(ffi.Pointer<Utf8>, ffi.Pointer<_PosixTimeval>);

typedef _WindowsCreateHardLinkNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf16>,
      ffi.Pointer<Utf16>,
      ffi.Pointer<ffi.Void>,
    );
typedef _WindowsCreateHardLinkDart =
    int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>, ffi.Pointer<ffi.Void>);

const int _posixOpenWriteOnly = 1;
final BigInt _maxI64 = (BigInt.one << 63) - BigInt.one;

final class _PosixTimeval extends ffi.Struct {
  @ffi.IntPtr()
  external int tvSec;

  @ffi.IntPtr()
  external int tvUsec;
}

final class _NativeDirectoryContext {
  const _NativeDirectoryContext(this.path);

  final String path;
}
