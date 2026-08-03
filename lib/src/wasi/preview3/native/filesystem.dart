import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../filesystem.dart';
import 'stat_layout.dart';

/// Dart VM-backed WASI 0.3 filesystem host.
final class WASIPreview3NativeFilesystemHost
    extends WASIPreview3FilesystemHost {
  /// Creates Preview3 filesystem preopens backed by real host directories.
  ///
  /// [preopens] maps guest paths such as `/` to host directory paths.
  WASIPreview3NativeFilesystemHost({
    required Map<String, String> preopens,
    bool canMutate = false,
    super.table,
  }) : super(preopens: _nativePreopens(preopens, canMutate: canMutate));
}

Map<String, WASIPreview3FilesystemDirectory> _nativePreopens(
  Map<String, String> preopens, {
  required bool canMutate,
}) {
  final filesystem = _NativeFilesystemState();
  final result = <String, WASIPreview3FilesystemDirectory>{};
  for (final entry in preopens.entries) {
    final path = io.Directory(entry.value).absolute.path;
    filesystem.addRoot(path);
    result[entry.key] = _nativeDirectory(
      path,
      canMutate: canMutate,
      filesystem: filesystem,
    );
  }
  return result;
}

WASIPreview3FilesystemDirectory _nativeDirectory(
  String hostPath, {
  required bool canMutate,
  required _NativeFilesystemState filesystem,
}) {
  final directory = filesystem.directory(io.Directory(hostPath).absolute.path);
  return WASIPreview3FilesystemDirectory.dynamic(
    canMutate: canMutate,
    createdFileCanMutate: canMutate,
    createdFileSupportsSync: true,
    createdFileSupportsSyncData: true,
    mutationContext: _NativeDirectoryContext(directory, filesystem),
    metadata: () => _nativeMetadata(directory.path),
    entries: () => _listNativeDirectoryEntries(
      directory.path,
      canMutate: canMutate,
      filesystem: filesystem,
    ),
    resolveEntry: (name) => _resolveNativeDirectoryEntry(
      directory.path,
      name,
      canMutate: canMutate,
      filesystem: filesystem,
    ),
    createDirectory: canMutate
        ? (name) => _createNativeDirectoryChild(directory.path, name)
        : null,
    createFile: canMutate
        ? (name) => _createNativeFileChild(
            directory.path,
            name,
            canMutate: canMutate,
            filesystem: filesystem,
          )
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
            filesystem,
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
        ? (name) =>
              _removeNativeDirectoryChild(directory.path, name, filesystem)
        : null,
    unlinkFile: canMutate
        ? (name) => _unlinkNativeFileChild(directory.path, name, filesystem)
        : null,
  );
}

Iterable<WASIPreview3FilesystemDirectoryEntry> _listNativeDirectoryEntries(
  String directoryPath, {
  required bool canMutate,
  required _NativeFilesystemState filesystem,
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
      filesystem: filesystem,
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
  required _NativeFilesystemState filesystem,
}) {
  if (!_isSafeNativeChildName(name)) {
    return null;
  }
  final path = _joinNative(directoryPath, name);
  return _nativeEntryForPath(
    name,
    path,
    canMutate: canMutate,
    filesystem: filesystem,
  );
}

WASIPreview3FilesystemDirectoryEntry? _nativeEntryForPath(
  String name,
  String path, {
  required bool canMutate,
  required _NativeFilesystemState filesystem,
}) {
  switch (io.FileSystemEntity.typeSync(path, followLinks: false)) {
    case io.FileSystemEntityType.directory:
      final directory = _nativeDirectory(
        path,
        canMutate: canMutate,
        filesystem: filesystem,
      );
      final state = _nativeDirectoryContext(directory)!.directory;
      return WASIPreview3FilesystemDirectoryEntry.directory(
        name,
        directory: directory,
        metadata: () => _nativeMetadata(state.path),
        openDescriptor: state.openDescriptor,
        closeDescriptor: state.closeDescriptor,
      );
    case io.FileSystemEntityType.file:
      final kind = _nativeFileKind(path);
      if (kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
        return WASIPreview3FilesystemDirectoryEntry.special(
          name,
          kind: kind,
          metadata: () => _nativeMetadata(path),
        );
      }
      final file = filesystem.file(path);
      return WASIPreview3FilesystemDirectoryEntry.regularFile(
        name,
        canMutate: canMutate,
        currentSize: file.currentSize,
        metadata: file.metadata,
        readChunk: file.readChunk,
        writeBytes: canMutate ? file.writeAt : null,
        advise: (_, _, _) => const WASIPreview3FilesystemMutationResult.ok(),
        setSize: canMutate ? file.setSize : null,
        syncData: file.sync,
        sync: file.sync,
        setTimes: canMutate ? file.setTimes : null,
        openDescriptor: file.openDescriptor,
        closeDescriptor: file.closeDescriptor,
      );
    case io.FileSystemEntityType.link:
      final target = io.Link(path).targetSync();
      return WASIPreview3FilesystemDirectoryEntry.symbolicLink(
        name,
        target: target,
        metadata: () => _nativeMetadata(
          path,
          symlinkFallbackSize: BigInt.from(utf8.encode(target).length),
        ),
      );
    case io.FileSystemEntityType.pipe:
      return WASIPreview3FilesystemDirectoryEntry.special(
        name,
        kind: WASIPreview3FilesystemDescriptorKind.fifo,
        metadata: () => _nativeMetadata(path),
      );
    case io.FileSystemEntityType.unixDomainSock:
      return WASIPreview3FilesystemDirectoryEntry.special(
        name,
        kind: WASIPreview3FilesystemDescriptorKind.socket,
        metadata: () => _nativeMetadata(path),
      );
    case io.FileSystemEntityType.notFound:
      return null;
  }
  return null;
}

WASIPreview3FilesystemDescriptorKind _nativeFileKind(String path) {
  if (io.Platform.isWindows) {
    return WASIPreview3FilesystemDescriptorKind.regularFile;
  }
  try {
    return switch (io.FileStat.statSync(path).mode & 0xf000) {
      0x1000 => WASIPreview3FilesystemDescriptorKind.fifo,
      0x2000 => WASIPreview3FilesystemDescriptorKind.characterDevice,
      0x6000 => WASIPreview3FilesystemDescriptorKind.blockDevice,
      0x8000 => WASIPreview3FilesystemDescriptorKind.regularFile,
      0xc000 => WASIPreview3FilesystemDescriptorKind.socket,
      _ => WASIPreview3FilesystemDescriptorKind.other,
    };
  } on io.FileSystemException {
    return WASIPreview3FilesystemDescriptorKind.other;
  }
}

WASIPreview3FilesystemMetadata _nativeMetadata(
  String path, {
  BigInt? symlinkFallbackSize,
}) {
  try {
    final metadata = _hostLstatMetadata(path);
    if (metadata != null) {
      return metadata;
    }
    if (symlinkFallbackSize != null) {
      return WASIPreview3FilesystemMetadata(size: symlinkFallbackSize);
    }
    final stat = io.FileStat.statSync(path);
    return WASIPreview3FilesystemMetadata(
      size: stat.size < 0 ? null : BigInt.from(stat.size),
      accessTimeNanos: _dateTimeNanos(stat.accessed),
      modificationTimeNanos: _dateTimeNanos(stat.modified),
      statusChangeTimeNanos: _dateTimeNanos(stat.changed),
    );
  } on io.FileSystemException {
    return const WASIPreview3FilesystemMetadata();
  }
}

WASIPreview3FilesystemMetadata? _hostLstatMetadata(String hostPath) {
  final abi = ffi.Abi.current();
  final layout = WASIPreview3NativeStatLayout.forAbi(abi);
  if (layout == null) {
    return null;
  }
  final pathPointer = hostPath.toNativeUtf8();
  final statBuffer = malloc<ffi.Uint8>(_hostStatBufferSize);
  try {
    final lstat = _posixLstatFunction(
      WASIPreview3NativeStatLayout.lstatSymbolForAbi(abi),
    );
    if (lstat(pathPointer, statBuffer.cast<ffi.Void>()) != 0) {
      return null;
    }
    return layout.read(statBuffer.asTypedList(_hostStatBufferSize));
  } catch (_) {
    return null;
  } finally {
    malloc.free(pathPointer);
    malloc.free(statBuffer);
  }
}

BigInt _dateTimeNanos(DateTime value) =>
    BigInt.from(value.toUtc().microsecondsSinceEpoch) * BigInt.from(1000);

Uint8List _readNativeFileChunk(String path, BigInt offset, int maxBytes) {
  if (offset < BigInt.zero || maxBytes <= 0) {
    return Uint8List(0);
  }
  final file = io.File(path).openSync(mode: io.FileMode.read);
  try {
    final length = file.lengthSync();
    final start = offset > BigInt.from(length) ? length : offset.toInt();
    file.setPositionSync(start);
    final remaining = length - start;
    return file.readSync(remaining < maxBytes ? remaining : maxBytes);
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
      WASIPreview3FilesystemMutationError.notPermitted,
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
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(newPath, error);
  }
}

WASIPreview3FilesystemMutationResult _renameNativeChild(
  String directoryPath,
  String oldName,
  WASIPreview3FilesystemDirectory targetDirectory,
  String newName,
  _NativeFilesystemState filesystem,
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
  if (oldPath != newPath) {
    final prepared = filesystem.prepareRename(oldPath, newPath);
    if (!prepared.isOk) return prepared;
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
    filesystem.rename(oldPath, newPath);
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(oldPath, error);
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
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(linkPath, error);
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
  required _NativeFilesystemState filesystem,
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
  return _nativeEntryForPath(
    name,
    path,
    canMutate: canMutate,
    filesystem: filesystem,
  );
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
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(path, error);
  }
}

WASIPreview3FilesystemMutationResult _removeNativeDirectoryChild(
  String directoryPath,
  String name,
  _NativeFilesystemState filesystem,
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
    final prepared = filesystem.prepareUnlink(path);
    if (!prepared.isOk) return prepared;
    directory.deleteSync();
    filesystem.unlinkDirectory(path);
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(path, error);
  }
}

WASIPreview3FilesystemMutationResult _unlinkNativeFileChild(
  String directoryPath,
  String name,
  _NativeFilesystemState filesystem,
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
  final prepared = filesystem.prepareUnlink(path);
  if (!prepared.isOk) return prepared;
  try {
    io.File(path).deleteSync();
    filesystem.unlink(path);
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(path, error);
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

WASIPreview3FilesystemMutationResult _syncNativeFile(String path) {
  final type = io.FileSystemEntity.typeSync(path, followLinks: false);
  if (type == io.FileSystemEntityType.notFound) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.noEntry,
    );
  }
  if (type != io.FileSystemEntityType.file) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.unsupported,
    );
  }
  io.RandomAccessFile? file;
  try {
    file = io.File(path).openSync(mode: io.FileMode.append);
    file.flushSync();
    file.closeSync();
    file = null;
    return const WASIPreview3FilesystemMutationResult.ok();
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(path, error);
  } finally {
    try {
      file?.closeSync();
    } on io.FileSystemException {
      // Preserve the flush/open error result above.
    }
  }
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
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(path, error);
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
  final microseconds = nanos ~/ BigInt.from(1000);
  if (!microseconds.isValidInt) {
    return null;
  }
  try {
    return DateTime.fromMicrosecondsSinceEpoch(
      microseconds.toInt(),
      isUtc: true,
    );
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
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(path, error);
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
  } on io.FileSystemException catch (error) {
    return _nativeMutationFailure(path, error);
  }
}

WASIPreview3FilesystemMutationResult _nativeMutationFailure(
  String path, [
  io.FileSystemException? exception,
]) {
  final mapped = _nativeMutationError(exception?.osError?.errorCode);
  if (mapped != null) {
    return WASIPreview3FilesystemMutationResult.error(mapped);
  }
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

WASIPreview3FilesystemMutationError? _nativeMutationError(int? errorCode) {
  if (errorCode == null) {
    return null;
  }
  if (io.Platform.isWindows) {
    return switch (errorCode) {
      2 || 3 => WASIPreview3FilesystemMutationError.noEntry,
      5 => WASIPreview3FilesystemMutationError.access,
      32 => WASIPreview3FilesystemMutationError.busy,
      80 || 183 => WASIPreview3FilesystemMutationError.exist,
      112 => WASIPreview3FilesystemMutationError.insufficientSpace,
      206 => WASIPreview3FilesystemMutationError.nameTooLong,
      267 => WASIPreview3FilesystemMutationError.notDirectory,
      _ => null,
    };
  }
  final darwin = io.Platform.isMacOS || io.Platform.isIOS;
  if (darwin) {
    return switch (errorCode) {
      1 => WASIPreview3FilesystemMutationError.notPermitted,
      2 => WASIPreview3FilesystemMutationError.noEntry,
      4 => WASIPreview3FilesystemMutationError.interrupted,
      5 => WASIPreview3FilesystemMutationError.io,
      6 => WASIPreview3FilesystemMutationError.noSuchDevice,
      9 => WASIPreview3FilesystemMutationError.badDescriptor,
      11 => WASIPreview3FilesystemMutationError.deadlock,
      12 => WASIPreview3FilesystemMutationError.insufficientMemory,
      13 => WASIPreview3FilesystemMutationError.access,
      16 => WASIPreview3FilesystemMutationError.busy,
      17 => WASIPreview3FilesystemMutationError.exist,
      18 => WASIPreview3FilesystemMutationError.crossDevice,
      19 => WASIPreview3FilesystemMutationError.noDevice,
      20 => WASIPreview3FilesystemMutationError.notDirectory,
      21 => WASIPreview3FilesystemMutationError.isDirectory,
      22 => WASIPreview3FilesystemMutationError.invalid,
      25 => WASIPreview3FilesystemMutationError.noTty,
      26 => WASIPreview3FilesystemMutationError.textFileBusy,
      27 => WASIPreview3FilesystemMutationError.fileTooLarge,
      28 => WASIPreview3FilesystemMutationError.insufficientSpace,
      29 => WASIPreview3FilesystemMutationError.invalidSeek,
      30 => WASIPreview3FilesystemMutationError.readOnly,
      31 => WASIPreview3FilesystemMutationError.tooManyLinks,
      32 => WASIPreview3FilesystemMutationError.pipe,
      36 => WASIPreview3FilesystemMutationError.inProgress,
      37 => WASIPreview3FilesystemMutationError.already,
      40 => WASIPreview3FilesystemMutationError.messageSize,
      62 => WASIPreview3FilesystemMutationError.loop,
      63 => WASIPreview3FilesystemMutationError.nameTooLong,
      66 => WASIPreview3FilesystemMutationError.notEmpty,
      69 => WASIPreview3FilesystemMutationError.quota,
      77 => WASIPreview3FilesystemMutationError.noLock,
      84 => WASIPreview3FilesystemMutationError.overflow,
      102 => WASIPreview3FilesystemMutationError.unsupported,
      104 => WASIPreview3FilesystemMutationError.notRecoverable,
      _ => null,
    };
  }
  return switch (errorCode) {
    1 => WASIPreview3FilesystemMutationError.notPermitted,
    2 => WASIPreview3FilesystemMutationError.noEntry,
    4 => WASIPreview3FilesystemMutationError.interrupted,
    5 => WASIPreview3FilesystemMutationError.io,
    6 => WASIPreview3FilesystemMutationError.noSuchDevice,
    9 => WASIPreview3FilesystemMutationError.badDescriptor,
    12 => WASIPreview3FilesystemMutationError.insufficientMemory,
    13 => WASIPreview3FilesystemMutationError.access,
    16 => WASIPreview3FilesystemMutationError.busy,
    17 => WASIPreview3FilesystemMutationError.exist,
    18 => WASIPreview3FilesystemMutationError.crossDevice,
    19 => WASIPreview3FilesystemMutationError.noDevice,
    20 => WASIPreview3FilesystemMutationError.notDirectory,
    21 => WASIPreview3FilesystemMutationError.isDirectory,
    22 => WASIPreview3FilesystemMutationError.invalid,
    25 => WASIPreview3FilesystemMutationError.noTty,
    26 => WASIPreview3FilesystemMutationError.textFileBusy,
    27 => WASIPreview3FilesystemMutationError.fileTooLarge,
    28 => WASIPreview3FilesystemMutationError.insufficientSpace,
    29 => WASIPreview3FilesystemMutationError.invalidSeek,
    30 => WASIPreview3FilesystemMutationError.readOnly,
    31 => WASIPreview3FilesystemMutationError.tooManyLinks,
    32 => WASIPreview3FilesystemMutationError.pipe,
    35 => WASIPreview3FilesystemMutationError.deadlock,
    36 => WASIPreview3FilesystemMutationError.nameTooLong,
    37 => WASIPreview3FilesystemMutationError.noLock,
    39 => WASIPreview3FilesystemMutationError.notEmpty,
    40 => WASIPreview3FilesystemMutationError.loop,
    75 => WASIPreview3FilesystemMutationError.overflow,
    90 => WASIPreview3FilesystemMutationError.messageSize,
    95 => WASIPreview3FilesystemMutationError.unsupported,
    114 => WASIPreview3FilesystemMutationError.already,
    115 => WASIPreview3FilesystemMutationError.inProgress,
    122 => WASIPreview3FilesystemMutationError.quota,
    131 => WASIPreview3FilesystemMutationError.notRecoverable,
    _ => null,
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
_PosixFsyncDart? _cachedPosixFsync;
_PosixCloseDart? _cachedPosixClose;
_PosixErrnoLocationDart? _cachedPosixErrnoLocation;
_PosixLinkDart? _cachedPosixLink;
_PosixUtimesDart? _cachedPosixUtimes;
_PosixLstatDart? _cachedPosixLstat;
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

_PosixFsyncDart _posixFsyncFunction() =>
    _cachedPosixFsync ??= _openPosixCLibrary()
        .lookupFunction<_PosixFsyncNative, _PosixFsyncDart>('fsync');

_PosixCloseDart _posixCloseFunction() =>
    _cachedPosixClose ??= _openPosixCLibrary()
        .lookupFunction<_PosixCloseNative, _PosixCloseDart>('close');

_PosixErrnoLocationDart _posixErrnoLocationFunction() =>
    _cachedPosixErrnoLocation ??= _openPosixCLibrary()
        .lookupFunction<_PosixErrnoLocationNative, _PosixErrnoLocationDart>(
          io.Platform.isMacOS || io.Platform.isIOS
              ? '__error'
              : io.Platform.isAndroid
              ? '__errno'
              : '__errno_location',
        );

_PosixLinkDart _posixLinkFunction() => _cachedPosixLink ??= _openPosixCLibrary()
    .lookupFunction<_PosixLinkNative, _PosixLinkDart>('link');

_PosixUtimesDart _posixUtimesFunction() =>
    _cachedPosixUtimes ??= _openPosixCLibrary()
        .lookupFunction<_PosixUtimesNative, _PosixUtimesDart>('utimes');

_PosixLstatDart _posixLstatFunction(String symbol) =>
    _cachedPosixLstat ??= _openPosixCLibrary()
        .lookupFunction<_PosixLstatNative, _PosixLstatDart>(symbol);

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

typedef _PosixFsyncNative = ffi.Int32 Function(ffi.Int32);
typedef _PosixFsyncDart = int Function(int);

typedef _PosixCloseNative = ffi.Int32 Function(ffi.Int32);
typedef _PosixCloseDart = int Function(int);

typedef _PosixErrnoLocationNative = ffi.Pointer<ffi.Int32> Function();
typedef _PosixErrnoLocationDart = ffi.Pointer<ffi.Int32> Function();

typedef _PosixLinkNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _PosixLinkDart = int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

typedef _PosixUtimesNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<_PosixTimeval>);
typedef _PosixUtimesDart =
    int Function(ffi.Pointer<Utf8>, ffi.Pointer<_PosixTimeval>);

typedef _PosixLstatNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Void>);
typedef _PosixLstatDart =
    int Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Void>);

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
const int _hostStatBufferSize = 256;

final Finalizer<_NativeFileRegistration> _nativeFileStateFinalizer =
    Finalizer<_NativeFileRegistration>((registration) {
      registration.filesystem._release(
        registration.path,
        registration.generation,
      );
    });

final Finalizer<_NativeDirectoryRegistration> _nativeDirectoryStateFinalizer =
    Finalizer<_NativeDirectoryRegistration>((registration) {
      registration.filesystem._releaseDirectory(
        registration.path,
        registration.generation,
      );
    });

final Finalizer<_NativeFileHandles> _nativeFileHandleFinalizer =
    Finalizer<_NativeFileHandles>((handles) => handles.close());

final class _PosixTimeval extends ffi.Struct {
  @ffi.IntPtr()
  external int tvSec;

  @ffi.IntPtr()
  external int tvUsec;
}

final class _NativeDirectoryContext {
  const _NativeDirectoryContext(this.directory, this.filesystem);

  final _NativeDirectoryState directory;
  final _NativeFilesystemState filesystem;

  String get path => directory.path;
}

final class _NativeFilesystemState {
  final List<_NativePathKeyRoot> _roots = <_NativePathKeyRoot>[];
  final Map<String, _NativeDirectoryReference> _directories =
      <String, _NativeDirectoryReference>{};
  final Map<String, _NativeFileReference> _files =
      <String, _NativeFileReference>{};
  int _nextGeneration = 0;

  void addRoot(String path) {
    _roots.add(
      _NativePathKeyRoot(
        _normalizeNativeSeparators(path),
        _detectCaseInsensitiveDirectory(path),
      ),
    );
    _roots.sort((left, right) => right.path.length.compareTo(left.path.length));
  }

  _NativeDirectoryState directory(String path) {
    final key = _key(path);
    final existing = _directories[key]?.directory.target;
    if (existing != null) return existing;
    _directories.remove(key);
    final directory = _NativeDirectoryState(path);
    _trackDirectory(path, directory);
    return directory;
  }

  _NativeFileState file(String path) {
    final key = _key(path);
    final existing = _files[key]?.file.target;
    if (existing != null) return existing;
    _files.remove(key);
    final file = _NativeFileState(path);
    _track(path, file);
    return file;
  }

  WASIPreview3FilesystemMutationResult prepareUnlink(String path) {
    final key = _key(path);
    final directoryReference = _directories[key];
    final directory = directoryReference?.directory.target;
    if (directory != null) return directory.prepareRemove();
    if (directoryReference != null) _directories.remove(key);
    final reference = _files[key];
    final file = reference?.file.target;
    if (file != null) return file.prepareUnlink();
    if (reference != null) _files.remove(key);
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  WASIPreview3FilesystemMutationResult prepareRename(
    String oldPath,
    String newPath,
  ) => _key(oldPath) == _key(newPath)
      ? const WASIPreview3FilesystemMutationResult.ok()
      : prepareUnlink(newPath);

  void rename(String oldPath, String newPath) {
    if (oldPath == newPath) return;
    final oldKey = _key(oldPath);
    final newKey = _key(newPath);
    if (oldKey == newKey) {
      _renameCaseOnly(oldPath, newPath, oldKey);
      return;
    }
    _remapDirectories(oldPath, newPath);
    _remove(newPath)?.unlink();
    final separator = io.Platform.pathSeparator;
    final prefix = '$oldKey$separator';
    final moved = <(String, _NativeFileState)>[];
    for (final entry in List<MapEntry<String, _NativeFileReference>>.of(
      _files.entries,
    )) {
      if (entry.key != oldKey && !entry.key.startsWith(prefix)) continue;
      final file = _remove(entry.key);
      if (file != null) moved.add((file._path, file));
    }
    for (final (path, file) in moved) {
      final nextPath = path == oldPath
          ? newPath
          : '$newPath${path.substring(oldPath.length)}';
      _remove(nextPath)?.unlink();
      file.rename(nextPath);
      _track(nextPath, file);
    }
  }

  void unlink(String path) {
    _remove(path)?.unlink();
  }

  void unlinkDirectory(String path) {
    _removeDirectory(path);
  }

  void _track(String path, _NativeFileState file) {
    final generation = _nextGeneration++;
    _files[_key(path)] = _NativeFileReference(generation, WeakReference(file));
    _nativeFileStateFinalizer.attach(
      file,
      _NativeFileRegistration(this, path, generation),
      detach: file._cacheDetachToken,
    );
  }

  void _trackDirectory(String path, _NativeDirectoryState directory) {
    final generation = _nextGeneration++;
    _directories[_key(path)] = _NativeDirectoryReference(
      generation,
      WeakReference(directory),
    );
    _nativeDirectoryStateFinalizer.attach(
      directory,
      _NativeDirectoryRegistration(this, path, generation),
      detach: directory._cacheDetachToken,
    );
  }

  void _remapDirectories(String oldPath, String newPath) {
    final separator = io.Platform.pathSeparator;
    final oldKey = _key(oldPath);
    final prefix = '$oldKey$separator';
    final moved = <(String, _NativeDirectoryState)>[];
    for (final entry in List<MapEntry<String, _NativeDirectoryReference>>.of(
      _directories.entries,
    )) {
      if (entry.key != oldKey && !entry.key.startsWith(prefix)) continue;
      final directory = _removeDirectory(entry.key);
      if (directory != null) moved.add((directory.path, directory));
    }
    for (final (path, directory) in moved) {
      final nextPath = path == oldPath
          ? newPath
          : '$newPath${path.substring(oldPath.length)}';
      _removeDirectory(nextPath);
      directory.rename(nextPath);
      _trackDirectory(nextPath, directory);
    }
  }

  _NativeFileState? _remove(String path) {
    final file = _files.remove(_key(path))?.file.target;
    if (file != null) {
      _nativeFileStateFinalizer.detach(file._cacheDetachToken);
    }
    return file;
  }

  _NativeDirectoryState? _removeDirectory(String path) {
    final directory = _directories.remove(_key(path))?.directory.target;
    if (directory != null) {
      _nativeDirectoryStateFinalizer.detach(directory._cacheDetachToken);
    }
    return directory;
  }

  void _release(String path, int generation) {
    final key = _key(path);
    if (_files[key]?.generation == generation) {
      _files.remove(key);
    }
  }

  void _releaseDirectory(String path, int generation) {
    final key = _key(path);
    if (_directories[key]?.generation == generation) {
      _directories.remove(key);
    }
  }

  void _renameCaseOnly(String oldPath, String newPath, String oldKey) {
    final separator = io.Platform.pathSeparator;
    final prefix = '$oldKey$separator';
    for (final entry in _directories.entries) {
      if (entry.key != oldKey && !entry.key.startsWith(prefix)) continue;
      final directory = entry.value.directory.target;
      if (directory == null) continue;
      directory.rename(
        directory.path == oldPath
            ? newPath
            : '$newPath${directory.path.substring(oldPath.length)}',
      );
    }
    for (final entry in _files.entries) {
      if (entry.key != oldKey && !entry.key.startsWith(prefix)) continue;
      final file = entry.value.file.target;
      if (file == null) continue;
      file.rename(
        file._path == oldPath
            ? newPath
            : '$newPath${file._path.substring(oldPath.length)}',
      );
    }
  }

  String _key(String path) {
    final normalized = _normalizeNativeSeparators(path);
    final separator = io.Platform.pathSeparator;
    for (final root in _roots) {
      if (normalized != root.path &&
          !normalized.startsWith('${root.path}$separator')) {
        continue;
      }
      return root.caseInsensitive ? normalized.toLowerCase() : normalized;
    }
    return normalized;
  }
}

final class _NativePathKeyRoot {
  const _NativePathKeyRoot(this.path, this.caseInsensitive);

  final String path;
  final bool caseInsensitive;
}

String _normalizeNativeSeparators(String path) => io.Platform.isWindows
    ? path.replaceAll('/', io.Platform.pathSeparator)
    : path;

bool _detectCaseInsensitiveDirectory(String path) {
  try {
    final entities = io.Directory(path).listSync(followLinks: false);
    final names = <String>{
      for (final entity in entities) _basename(entity.path),
    };
    for (final entity in entities) {
      final name = _basename(entity.path);
      final variant = _asciiCaseVariant(name);
      if (variant == null) continue;
      if (names.contains(variant)) return false;
      final candidate = _joinNative(path, variant);
      if (io.FileSystemEntity.typeSync(candidate, followLinks: false) ==
          io.FileSystemEntityType.notFound) {
        return false;
      }
      return io.FileSystemEntity.identicalSync(entity.path, candidate);
    }

    final rootDevice = _nativeDevice(path);
    var current = io.Directory(path).absolute;
    while (rootDevice != null) {
      final parent = current.parent;
      if (parent.path == current.path ||
          _nativeDevice(parent.path) != rootDevice) {
        break;
      }
      final variant = _asciiCaseVariant(_basename(current.path));
      if (variant != null) {
        final currentName = _basename(current.path);
        final parentNames = <String>{
          for (final entity in parent.listSync(followLinks: false))
            _basename(entity.path),
        };
        if (parentNames.contains(currentName) &&
            parentNames.contains(variant)) {
          return false;
        }
        final candidate = _joinNative(parent.path, variant);
        if (io.FileSystemEntity.typeSync(candidate, followLinks: false) ==
            io.FileSystemEntityType.notFound) {
          return false;
        }
        return io.FileSystemEntity.identicalSync(current.path, candidate);
      }
      current = parent;
    }
  } on io.FileSystemException {
    // Fall through to the conservative platform default.
  }
  return io.Platform.isWindows;
}

String? _nativeDevice(String path) {
  final identity = _hostLstatMetadata(path)?.objectIdentity;
  if (identity == null) return null;
  final separator = identity.indexOf(':');
  return separator < 0 ? null : identity.substring(0, separator);
}

String? _asciiCaseVariant(String value) {
  for (var index = 0; index < value.length; index++) {
    final code = value.codeUnitAt(index);
    if (code >= 0x41 && code <= 0x5a) {
      return '${value.substring(0, index)}${String.fromCharCode(code + 0x20)}'
          '${value.substring(index + 1)}';
    }
    if (code >= 0x61 && code <= 0x7a) {
      return '${value.substring(0, index)}${String.fromCharCode(code - 0x20)}'
          '${value.substring(index + 1)}';
    }
  }
  return null;
}

final class _NativeDirectoryState {
  _NativeDirectoryState(this.path);

  final Object _cacheDetachToken = Object();
  String path;
  int _liveDescriptors = 0;

  WASIPreview3FilesystemMutationResult openDescriptor(Set<String> flags) {
    _liveDescriptors++;
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  void closeDescriptor(Set<String> flags) {
    if (_liveDescriptors > 0) _liveDescriptors--;
  }

  WASIPreview3FilesystemMutationResult prepareRemove() => _liveDescriptors > 0
      ? const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.unsupported,
        )
      : const WASIPreview3FilesystemMutationResult.ok();

  void rename(String nextPath) {
    path = nextPath;
  }
}

final class _NativeDirectoryReference {
  const _NativeDirectoryReference(this.generation, this.directory);

  final int generation;
  final WeakReference<_NativeDirectoryState> directory;
}

final class _NativeDirectoryRegistration {
  const _NativeDirectoryRegistration(
    this.filesystem,
    this.path,
    this.generation,
  );

  final _NativeFilesystemState filesystem;
  final String path;
  final int generation;
}

final class _NativeFileReference {
  const _NativeFileReference(this.generation, this.file);

  final int generation;
  final WeakReference<_NativeFileState> file;
}

final class _NativeFileRegistration {
  const _NativeFileRegistration(this.filesystem, this.path, this.generation);

  final _NativeFilesystemState filesystem;
  final String path;
  final int generation;
}

final class _NativeFileHandles {
  io.RandomAccessFile? reader;
  int writer = -1;

  void closeReader() {
    final file = reader;
    reader = null;
    if (file == null) return;
    try {
      file.closeSync();
    } catch (_) {
      // The descriptor was already closed by the host platform.
    }
  }

  void closeWriter() {
    final fd = writer;
    writer = -1;
    if (fd < 0) return;
    try {
      _posixCloseFunction()(fd);
    } catch (_) {
      // Finalization and resource drops are best-effort after ownership ends.
    }
  }

  void close() {
    closeReader();
    closeWriter();
  }
}

final class _NativeFileState {
  _NativeFileState(this._path) : _knownSize = _nativeFileSize(_path) {
    _nativeFileHandleFinalizer.attach(
      this,
      _handles,
      detach: _handleDetachToken,
    );
  }

  final Object _cacheDetachToken = Object();
  final Object _handleDetachToken = Object();
  final _NativeFileHandles _handles = _NativeFileHandles();
  String _path;
  BigInt _knownSize;
  bool _linked = true;
  int _liveDescriptors = 0;
  int _readers = 0;
  int _writers = 0;

  WASIPreview3FilesystemMutationResult openDescriptor(Set<String> flags) {
    if (io.Platform.isWindows) {
      _liveDescriptors++;
      return const WASIPreview3FilesystemMutationResult.ok();
    }
    io.RandomAccessFile? openedReader;
    var openedWriter = -1;
    try {
      if (flags.contains('read') && _readers == 0) {
        openedReader = io.File(_path).openSync(mode: io.FileMode.read);
      }
      if (flags.contains('write') && _writers == 0) {
        final opened = _openNativeFileForWriting(_path);
        openedWriter = opened.descriptor;
        if (openedWriter < 0) {
          openedReader?.closeSync();
          return WASIPreview3FilesystemMutationResult.error(
            _nativeMutationError(opened.errorCode) ??
                WASIPreview3FilesystemMutationError.io,
          );
        }
      }
      if (openedReader != null) {
        _handles.reader = openedReader;
        _knownSize = BigInt.from(openedReader.lengthSync());
      }
      if (openedWriter >= 0) _handles.writer = openedWriter;
      if (flags.contains('read')) _readers++;
      if (flags.contains('write')) _writers++;
      _liveDescriptors++;
      return const WASIPreview3FilesystemMutationResult.ok();
    } on io.FileSystemException catch (error) {
      try {
        openedReader?.closeSync();
      } on io.FileSystemException {
        // Preserve the original open failure.
      }
      if (openedWriter >= 0) _posixCloseFunction()(openedWriter);
      return _nativeMutationFailure(_path, error);
    } catch (_) {
      try {
        openedReader?.closeSync();
      } on io.FileSystemException {
        // Preserve the original host failure.
      }
      if (openedWriter >= 0) _posixCloseFunction()(openedWriter);
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.io,
      );
    }
  }

  void closeDescriptor(Set<String> flags) {
    if (_liveDescriptors == 0) return;
    _liveDescriptors--;
    if (io.Platform.isWindows) return;
    if (flags.contains('read') && _readers > 0 && --_readers == 0) {
      _handles.closeReader();
    }
    if (flags.contains('write') && _writers > 0 && --_writers == 0) {
      _handles.closeWriter();
    }
  }

  WASIPreview3FilesystemMutationResult prepareUnlink() {
    if (io.Platform.isWindows && _liveDescriptors != 0) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.unsupported,
      );
    }
    final missingReader = _readers != 0 && _handles.reader == null;
    final missingWriter = _writers != 0 && _handles.writer < 0;
    if (missingReader || missingWriter) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.io,
      );
    }
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  BigInt currentSize() {
    if (_linked) {
      _knownSize = _nativeFileSize(_path, fallback: _knownSize);
    } else {
      try {
        final handle = _handles.reader;
        if (handle != null) _knownSize = BigInt.from(handle.lengthSync());
      } on io.FileSystemException {
        // Preserve the last size observed through this descriptor.
      }
    }
    return _knownSize;
  }

  WASIPreview3FilesystemMetadata metadata() {
    if (!_linked) {
      return WASIPreview3FilesystemMetadata(size: _knownSize);
    }
    final metadata = _nativeMetadata(_path);
    final size = metadata.size;
    if (size != null) {
      _knownSize = size;
    }
    return metadata;
  }

  Uint8List readChunk(BigInt offset, int maxBytes) {
    if (_linked) return _readNativeFileChunk(_path, offset, maxBytes);
    final handle = _handles.reader;
    if (handle == null ||
        offset < BigInt.zero ||
        offset > _maxI64 ||
        maxBytes <= 0) {
      return Uint8List(0);
    }
    try {
      final length = handle.lengthSync();
      final start = offset > BigInt.from(length) ? length : offset.toInt();
      handle.setPositionSync(start);
      final remaining = length - start;
      return handle.readSync(remaining < maxBytes ? remaining : maxBytes);
    } on io.FileSystemException {
      return Uint8List(0);
    }
  }

  WASIPreview3FilesystemMutationResult writeAt(BigInt offset, Uint8List bytes) {
    if (!_linked) {
      if (offset < BigInt.zero || offset > _maxI64) {
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.invalid,
        );
      }
      final end = offset + BigInt.from(bytes.length);
      if (end > _maxI64) {
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.fileTooLarge,
        );
      }
      final fd = _handles.writer;
      if (fd < 0) {
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.noEntry,
        );
      }
      final result = _writeNativeFileDescriptorAt(fd, offset.toInt(), bytes);
      if (result.isOk && end > _knownSize) {
        _knownSize = end;
      }
      return result;
    }
    final result = _writeNativeFileAt(_path, offset, bytes);
    if (result.isOk) {
      currentSize();
    }
    return result;
  }

  WASIPreview3FilesystemMutationResult setSize(BigInt size) {
    if (!_linked) {
      if (size < BigInt.zero || size > _maxI64) {
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.invalid,
        );
      }
      final fd = _handles.writer;
      if (fd < 0) {
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.noEntry,
        );
      }
      try {
        if (_posixFtruncateFunction()(fd, size.toInt()) != 0) {
          return const WASIPreview3FilesystemMutationResult.error(
            WASIPreview3FilesystemMutationError.io,
          );
        }
        _knownSize = size;
        return const WASIPreview3FilesystemMutationResult.ok();
      } catch (_) {
        return const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.io,
        );
      }
    }
    final result = _setNativeFileSize(_path, size);
    if (result.isOk) {
      _knownSize = size;
    }
    return result;
  }

  WASIPreview3FilesystemMutationResult sync() {
    if (_linked) return _syncNativeFile(_path);
    final fd = _handles.writer;
    if (fd < 0) {
      if (_handles.reader != null) {
        return const WASIPreview3FilesystemMutationResult.ok();
      }
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.noEntry,
      );
    }
    try {
      return _posixFsyncFunction()(fd) == 0
          ? const WASIPreview3FilesystemMutationResult.ok()
          : const WASIPreview3FilesystemMutationResult.error(
              WASIPreview3FilesystemMutationError.io,
            );
    } catch (_) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.io,
      );
    }
  }

  WASIPreview3FilesystemMutationResult setTimes(
    WASIPreview3FilesystemTimestampUpdate update,
  ) => _linked
      ? _setNativePathTimes(_path, update)
      : const WASIPreview3FilesystemMutationResult.ok();

  void rename(String path) {
    _path = path;
  }

  void unlink() {
    _linked = false;
    currentSize();
  }
}

({int descriptor, int? errorCode}) _openNativeFileForWriting(String path) {
  final pathPointer = path.toNativeUtf8();
  try {
    final descriptor = _posixOpenFunction()(
      pathPointer,
      _posixOpenWriteOnly,
      0,
    );
    int? errorCode;
    if (descriptor < 0) {
      try {
        errorCode = _posixErrnoLocationFunction()().value;
      } catch (_) {
        // Fall back to the stable generic I/O error below.
      }
    }
    return (descriptor: descriptor, errorCode: errorCode);
  } finally {
    malloc.free(pathPointer);
  }
}

WASIPreview3FilesystemMutationResult _writeNativeFileDescriptorAt(
  int fd,
  int offset,
  Uint8List bytes,
) {
  if (bytes.isEmpty) {
    return const WASIPreview3FilesystemMutationResult.ok();
  }
  final dataPointer = malloc<ffi.Uint8>(bytes.length);
  try {
    dataPointer.asTypedList(bytes.length).setAll(0, bytes);
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
  } catch (_) {
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.io,
    );
  } finally {
    malloc.free(dataPointer);
  }
}

BigInt _nativeFileSize(String path, {BigInt? fallback}) {
  try {
    return BigInt.from(io.File(path).lengthSync());
  } on io.FileSystemException {
    return fallback ?? BigInt.zero;
  }
}
