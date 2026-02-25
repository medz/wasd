import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'hash.dart';

abstract interface class WasiFileDescriptor {
  bool get readable;
  bool get writable;
  int get inode;
  int get size;
  int get atimeNs;
  int get mtimeNs;
  int get ctimeNs;

  int write(Uint8List bytes);
  Uint8List read(int maxBytes);
  int seek(int offset, int whence);
  int tell();
  void flush();
  void truncate(int size);
  void setTimes({int? atimeNs, int? mtimeNs, int? ctimeNs});
  void close();
}

enum WasiFileType {
  unknown,
  blockDevice,
  characterDevice,
  directory,
  regularFile,
  socketDgram,
  socketStream,
  symbolicLink,
}

final class WasiPathStat {
  const WasiPathStat({
    required this.fileType,
    required this.inode,
    required this.size,
    required this.atimeNs,
    required this.mtimeNs,
    required this.ctimeNs,
  });

  final WasiFileType fileType;
  final int inode;
  final int size;
  final int atimeNs;
  final int mtimeNs;
  final int ctimeNs;
}

final class WasiDirectoryEntry {
  const WasiDirectoryEntry({
    required this.name,
    required this.fileType,
    required this.inode,
  });

  final String name;
  final WasiFileType fileType;
  final int inode;
}

abstract interface class WasiFileSystem {
  WasiFileDescriptor open({
    required String path,
    required bool create,
    required bool truncate,
    required bool read,
    required bool write,
    required bool exclusive,
  });
}

abstract interface class WasiPathMetadataFileSystem {
  WasiPathStat statPath(String path);
}

abstract interface class WasiDirectoryListingFileSystem {
  List<WasiDirectoryEntry> readDirectory(String path);
}

abstract interface class WasiMutablePathFileSystem {
  void unlinkFile(String path);
  void rename({required String sourcePath, required String destinationPath});
  void createDirectory(String path);
  void removeDirectory(String path);
}

abstract interface class WasiPathTimesFileSystem {
  void setPathTimes({
    required String path,
    int? atimeNs,
    int? mtimeNs,
    int? ctimeNs,
  });
}

abstract interface class WasiPathLinkFileSystem {
  void link({required String sourcePath, required String destinationPath});
  void symlink({required String targetPath, required String linkPath});
  String readlink(String path);
}

enum WasiFsError {
  notFound,
  exists,
  invalid,
  permissionDenied,
  notSupported,
  directoryNotEmpty,
  notDirectory,
  isDirectory,
}

final class WasiFsException implements Exception {
  const WasiFsException(this.error, [this.message = '']);

  final WasiFsError error;
  final String message;

  @override
  String toString() {
    if (message.isEmpty) {
      return 'WasiFsException($error)';
    }
    return 'WasiFsException($error, $message)';
  }
}

final class WasiInMemoryFileSystem
    implements
        WasiFileSystem,
        WasiMutablePathFileSystem,
        WasiPathTimesFileSystem,
        WasiPathLinkFileSystem,
        WasiPathMetadataFileSystem,
        WasiDirectoryListingFileSystem {
  WasiInMemoryFileSystem();

  final Map<String, _InMemoryFile> _files = <String, _InMemoryFile>{};
  final Map<String, _InMemorySymlink> _symlinks = <String, _InMemorySymlink>{};
  final Set<String> _directories = <String>{'/'};
  int _nextInode = 1;

  @override
  WasiFileDescriptor open({
    required String path,
    required bool create,
    required bool truncate,
    required bool read,
    required bool write,
    required bool exclusive,
  }) {
    final normalizedPath = normalizeAbsolutePath(path);
    final resolvedPath = _resolveFilePath(normalizedPath);
    if (_directories.contains(resolvedPath)) {
      throw const WasiFsException(
        WasiFsError.isDirectory,
        'Cannot open a directory as a file.',
      );
    }
    final parent = _parentPath(resolvedPath);
    if (!_directories.contains(parent)) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    final existing = _files[resolvedPath];

    if (existing == null) {
      if (!create) {
        throw const WasiFsException(WasiFsError.notFound);
      }
      final created = _InMemoryFile(_nextInode++);
      _files[resolvedPath] = created;
      return _InMemoryFileDescriptor(
        created,
        readable: read,
        writable: write,
        truncateOnOpen: truncate,
      );
    }

    if (create && exclusive) {
      throw const WasiFsException(WasiFsError.exists);
    }

    return _InMemoryFileDescriptor(
      existing,
      readable: read,
      writable: write,
      truncateOnOpen: truncate,
    );
  }

  Uint8List? readFileBytes(String path) {
    final normalizedPath = normalizeAbsolutePath(path);
    final resolvedPath = _resolveFilePath(normalizedPath);
    if (_directories.contains(resolvedPath)) {
      return null;
    }
    final file = _files[resolvedPath];
    if (file == null) {
      return null;
    }
    return Uint8List.fromList(file.bytes);
  }

  String? readFileText(String path, {Encoding encoding = utf8}) {
    final bytes = readFileBytes(path);
    if (bytes == null) {
      return null;
    }
    return encoding.decode(bytes);
  }

  Map<String, Uint8List> snapshot() {
    return UnmodifiableMapView<String, Uint8List>(
      _files.map(
        (path, file) => MapEntry(path, Uint8List.fromList(file.bytes)),
      ),
    );
  }

  List<String> snapshotDirectories() {
    final directories = _directories.toList(growable: false)..sort();
    return directories;
  }

  Map<String, String> snapshotSymlinks() {
    final entries = <String, String>{};
    final paths = _symlinks.keys.toList(growable: false)..sort();
    for (final path in paths) {
      entries[path] = _symlinks[path]!.targetPath;
    }
    return UnmodifiableMapView<String, String>(entries);
  }

  @override
  WasiPathStat statPath(String path) {
    final normalizedPath = normalizeAbsolutePath(path);
    if (_directories.contains(normalizedPath)) {
      return WasiPathStat(
        fileType: WasiFileType.directory,
        inode: _inodeFromPath(normalizedPath),
        size: 0,
        atimeNs: 0,
        mtimeNs: 0,
        ctimeNs: 0,
      );
    }

    final symlink = _symlinks[normalizedPath];
    if (symlink != null) {
      return WasiPathStat(
        fileType: WasiFileType.symbolicLink,
        inode: symlink.inode,
        size: utf8.encode(symlink.targetPath).length,
        atimeNs: symlink.atimeNs,
        mtimeNs: symlink.mtimeNs,
        ctimeNs: symlink.ctimeNs,
      );
    }

    final file = _files[normalizedPath];
    if (file == null) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    return WasiPathStat(
      fileType: WasiFileType.regularFile,
      inode: file.inode,
      size: file.bytes.length,
      atimeNs: file.atimeNs,
      mtimeNs: file.mtimeNs,
      ctimeNs: file.ctimeNs,
    );
  }

  @override
  List<WasiDirectoryEntry> readDirectory(String path) {
    final normalizedPath = normalizeAbsolutePath(path);
    if (!_directories.contains(normalizedPath)) {
      throw const WasiFsException(WasiFsError.notDirectory);
    }

    final entries = <WasiDirectoryEntry>[];
    final prefix = normalizedPath == '/' ? '/' : '$normalizedPath/';

    for (final directory in _directories) {
      if (directory == normalizedPath || !directory.startsWith(prefix)) {
        continue;
      }
      final remainder = directory.substring(prefix.length);
      if (remainder.isEmpty || remainder.contains('/')) {
        continue;
      }
      entries.add(
        WasiDirectoryEntry(
          name: remainder,
          fileType: WasiFileType.directory,
          inode: _inodeFromPath(directory),
        ),
      );
    }

    for (final entry in _files.entries) {
      final filePath = entry.key;
      if (!filePath.startsWith(prefix)) {
        continue;
      }
      final remainder = filePath.substring(prefix.length);
      if (remainder.isEmpty || remainder.contains('/')) {
        continue;
      }
      entries.add(
        WasiDirectoryEntry(
          name: remainder,
          fileType: WasiFileType.regularFile,
          inode: entry.value.inode,
        ),
      );
    }

    for (final entry in _symlinks.entries) {
      final linkPath = entry.key;
      if (!linkPath.startsWith(prefix)) {
        continue;
      }
      final remainder = linkPath.substring(prefix.length);
      if (remainder.isEmpty || remainder.contains('/')) {
        continue;
      }
      entries.add(
        WasiDirectoryEntry(
          name: remainder,
          fileType: WasiFileType.symbolicLink,
          inode: entry.value.inode,
        ),
      );
    }

    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  static String normalizeAbsolutePath(String path) {
    if (path.isEmpty) {
      throw const WasiFsException(
        WasiFsError.invalid,
        'Path must not be empty.',
      );
    }

    final rawParts = path.split('/');
    final parts = <String>[];
    for (final rawPart in rawParts) {
      if (rawPart.isEmpty || rawPart == '.') {
        continue;
      }
      if (rawPart == '..') {
        if (parts.isEmpty) {
          throw const WasiFsException(
            WasiFsError.permissionDenied,
            'Path escapes root.',
          );
        }
        parts.removeLast();
        continue;
      }
      parts.add(rawPart);
    }

    if (parts.isEmpty) {
      return '/';
    }
    return '/${parts.join('/')}';
  }

  @override
  void unlinkFile(String path) {
    final normalizedPath = normalizeAbsolutePath(path);
    if (normalizedPath == '/' || _directories.contains(normalizedPath)) {
      throw const WasiFsException(
        WasiFsError.isDirectory,
        'Cannot unlink a directory path.',
      );
    }
    final removed = _files.remove(normalizedPath);
    if (removed == null && _symlinks.remove(normalizedPath) == null) {
      throw const WasiFsException(WasiFsError.notFound);
    }
  }

  @override
  void rename({required String sourcePath, required String destinationPath}) {
    final source = normalizeAbsolutePath(sourcePath);
    final destination = normalizeAbsolutePath(destinationPath);
    if (source == '/' || destination == '/') {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'Cannot rename root directory.',
      );
    }
    if (destination.startsWith('$source/')) {
      throw const WasiFsException(
        WasiFsError.invalid,
        'Destination cannot be inside source.',
      );
    }
    final destinationParent = _parentPath(destination);
    if (!_directories.contains(destinationParent)) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    if (_entryExists(destination)) {
      throw const WasiFsException(WasiFsError.exists);
    }

    final file = _files.remove(source);
    if (file != null) {
      _files[destination] = file;
      return;
    }

    final symlink = _symlinks.remove(source);
    if (symlink != null) {
      _symlinks[destination] = symlink;
      return;
    }

    if (!_directories.contains(source)) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    final sourcePrefix = '$source/';
    final movingDirectories = _directories
        .where((path) => path == source || path.startsWith(sourcePrefix))
        .toList(growable: false);
    final movingFiles = _files.keys
        .where((path) => path.startsWith(sourcePrefix))
        .toList(growable: false);
    final movingSymlinks = _symlinks.keys
        .where((path) => path.startsWith(sourcePrefix))
        .toList(growable: false);

    String remap(String path) {
      if (path == source) {
        return destination;
      }
      return '$destination/${path.substring(sourcePrefix.length)}';
    }

    final movingSet = <String>{
      ...movingDirectories,
      ...movingFiles,
      ...movingSymlinks,
    };
    for (final oldPath in movingSet) {
      final nextPath = remap(oldPath);
      if (movingSet.contains(nextPath)) {
        continue;
      }
      if (_entryExists(nextPath)) {
        throw const WasiFsException(WasiFsError.exists);
      }
    }

    final movedFiles = <String, _InMemoryFile>{};
    final movedSymlinks = <String, _InMemorySymlink>{};
    for (final oldPath in movingFiles) {
      movedFiles[remap(oldPath)] = _files.remove(oldPath)!;
    }
    for (final oldPath in movingSymlinks) {
      movedSymlinks[remap(oldPath)] = _symlinks.remove(oldPath)!;
    }

    final movedDirectories = movingDirectories
        .map(remap)
        .toList(growable: false);
    for (final oldPath in movingDirectories) {
      _directories.remove(oldPath);
    }
    _directories.addAll(movedDirectories);
    _files.addAll(movedFiles);
    _symlinks.addAll(movedSymlinks);
  }

  @override
  void createDirectory(String path) {
    final normalizedPath = normalizeAbsolutePath(path);
    if (normalizedPath == '/') {
      throw const WasiFsException(WasiFsError.exists);
    }
    if (_directories.contains(normalizedPath) ||
        _files.containsKey(normalizedPath) ||
        _symlinks.containsKey(normalizedPath)) {
      throw const WasiFsException(WasiFsError.exists);
    }
    final parent = _parentPath(normalizedPath);
    if (!_directories.contains(parent)) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    _directories.add(normalizedPath);
  }

  @override
  void removeDirectory(String path) {
    final normalizedPath = normalizeAbsolutePath(path);
    if (normalizedPath == '/') {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'Cannot remove root directory.',
      );
    }
    if (!_directories.contains(normalizedPath)) {
      throw const WasiFsException(WasiFsError.notDirectory);
    }

    final prefix = '$normalizedPath/';
    final hasNestedDirectory = _directories.any((directory) {
      return directory != normalizedPath && directory.startsWith(prefix);
    });
    final hasNestedFiles = _files.keys.any(
      (filePath) => filePath.startsWith(prefix),
    );
    final hasNestedSymlinks = _symlinks.keys.any(
      (symlinkPath) => symlinkPath.startsWith(prefix),
    );
    if (hasNestedDirectory || hasNestedFiles || hasNestedSymlinks) {
      throw const WasiFsException(WasiFsError.directoryNotEmpty);
    }

    _directories.remove(normalizedPath);
  }

  @override
  void setPathTimes({
    required String path,
    int? atimeNs,
    int? mtimeNs,
    int? ctimeNs,
  }) {
    final normalizedPath = normalizeAbsolutePath(path);
    final file = _files[normalizedPath];
    if (file != null) {
      if (atimeNs != null) {
        file.atimeNs = atimeNs;
      }
      if (mtimeNs != null) {
        file.mtimeNs = mtimeNs;
      }
      if (ctimeNs != null) {
        file.ctimeNs = ctimeNs;
      }
      return;
    }

    final symlink = _symlinks[normalizedPath];
    if (symlink != null) {
      if (atimeNs != null) {
        symlink.atimeNs = atimeNs;
      }
      if (mtimeNs != null) {
        symlink.mtimeNs = mtimeNs;
      }
      if (ctimeNs != null) {
        symlink.ctimeNs = ctimeNs;
      }
      return;
    }

    if (_directories.contains(normalizedPath)) {
      // Directory timestamps are not tracked in the in-memory backend.
      return;
    }
    throw const WasiFsException(WasiFsError.notFound);
  }

  @override
  void link({required String sourcePath, required String destinationPath}) {
    final source = normalizeAbsolutePath(sourcePath);
    final destination = normalizeAbsolutePath(destinationPath);

    if (_directories.contains(source)) {
      throw const WasiFsException(WasiFsError.isDirectory);
    }
    final file = _files[source];
    if (file == null) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    if (_entryExists(destination)) {
      throw const WasiFsException(WasiFsError.exists);
    }

    final destinationParent = _parentPath(destination);
    if (!_directories.contains(destinationParent)) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    _files[destination] = file;
  }

  @override
  void symlink({required String targetPath, required String linkPath}) {
    final normalizedLinkPath = normalizeAbsolutePath(linkPath);
    if (_entryExists(normalizedLinkPath)) {
      throw const WasiFsException(WasiFsError.exists);
    }

    final parent = _parentPath(normalizedLinkPath);
    if (!_directories.contains(parent)) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    _symlinks[normalizedLinkPath] = _InMemorySymlink(_nextInode++, targetPath);
  }

  @override
  String readlink(String path) {
    final normalizedPath = normalizeAbsolutePath(path);
    final link = _symlinks[normalizedPath];
    if (link == null) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    return link.targetPath;
  }

  bool _entryExists(String normalizedPath) {
    return _directories.contains(normalizedPath) ||
        _files.containsKey(normalizedPath) ||
        _symlinks.containsKey(normalizedPath);
  }

  String _resolveFilePath(String normalizedPath) {
    var current = normalizedPath;
    final seen = <String>{};
    for (var depth = 0; depth < 32; depth++) {
      final link = _symlinks[current];
      if (link == null) {
        return current;
      }
      if (!seen.add(current)) {
        throw const WasiFsException(
          WasiFsError.invalid,
          'Symlink loop detected.',
        );
      }
      current = _resolveSymlinkTarget(
        linkPath: current,
        targetPath: link.targetPath,
      );
    }
    throw const WasiFsException(
      WasiFsError.invalid,
      'Symlink resolution depth exceeded.',
    );
  }

  static String _resolveSymlinkTarget({
    required String linkPath,
    required String targetPath,
  }) {
    if (targetPath.startsWith('/')) {
      return normalizeAbsolutePath(targetPath);
    }
    final parent = _parentPath(linkPath);
    final joined = parent == '/' ? '/$targetPath' : '$parent/$targetPath';
    return normalizeAbsolutePath(joined);
  }

  static String _parentPath(String absolutePath) {
    if (absolutePath == '/') {
      return '/';
    }
    final lastSlash = absolutePath.lastIndexOf('/');
    if (lastSlash <= 0) {
      return '/';
    }
    return absolutePath.substring(0, lastSlash);
  }

  static int _inodeFromPath(String path) {
    return WasmHash.fnv1a64Positive(path);
  }
}

final class _InMemoryFile {
  _InMemoryFile(this.inode)
    : atimeNs = _nowNs(),
      mtimeNs = _nowNs(),
      ctimeNs = _nowNs();

  final int inode;
  final List<int> bytes = <int>[];
  int atimeNs;
  int mtimeNs;
  int ctimeNs;

  static int _nowNs() => DateTime.now().microsecondsSinceEpoch * 1000;
}

final class _InMemorySymlink {
  _InMemorySymlink(this.inode, this.targetPath)
    : atimeNs = _InMemoryFile._nowNs(),
      mtimeNs = _InMemoryFile._nowNs(),
      ctimeNs = _InMemoryFile._nowNs();

  final int inode;
  final String targetPath;
  int atimeNs;
  int mtimeNs;
  int ctimeNs;
}

final class _InMemoryFileDescriptor implements WasiFileDescriptor {
  _InMemoryFileDescriptor(
    this._file, {
    required this.readable,
    required this.writable,
    required bool truncateOnOpen,
  }) {
    if (truncateOnOpen) {
      _file.bytes.clear();
    }
  }

  final _InMemoryFile _file;
  @override
  final bool readable;
  @override
  final bool writable;

  int _cursor = 0;
  bool _closed = false;

  @override
  int get inode => _file.inode;

  @override
  int get size => _file.bytes.length;

  @override
  int get atimeNs => _file.atimeNs;

  @override
  int get mtimeNs => _file.mtimeNs;

  @override
  int get ctimeNs => _file.ctimeNs;

  @override
  int write(Uint8List bytes) {
    if (_closed || !writable) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is not writable.',
      );
    }
    if (bytes.isEmpty) {
      return 0;
    }

    final requiredLength = _cursor + bytes.length;
    while (_file.bytes.length < requiredLength) {
      _file.bytes.add(0);
    }
    for (var i = 0; i < bytes.length; i++) {
      _file.bytes[_cursor + i] = bytes[i];
    }
    _cursor += bytes.length;
    _file.mtimeNs = _InMemoryFile._nowNs();
    return bytes.length;
  }

  @override
  Uint8List read(int maxBytes) {
    if (_closed || !readable) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is not readable.',
      );
    }
    if (maxBytes <= 0) {
      return Uint8List(0);
    }

    final available = _file.bytes.length - _cursor;
    if (available <= 0) {
      return Uint8List(0);
    }
    final count = available < maxBytes ? available : maxBytes;
    final out = Uint8List.fromList(
      _file.bytes.sublist(_cursor, _cursor + count),
    );
    _cursor += count;
    _file.atimeNs = _InMemoryFile._nowNs();
    return out;
  }

  @override
  int seek(int offset, int whence) {
    if (_closed) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is closed.',
      );
    }

    final base = switch (whence) {
      0 => 0,
      1 => _cursor,
      2 => _file.bytes.length,
      _ => throw const WasiFsException(
        WasiFsError.invalid,
        'Invalid seek whence.',
      ),
    };
    final target = base + offset;
    if (target < 0) {
      throw const WasiFsException(
        WasiFsError.invalid,
        'Seek target must be non-negative.',
      );
    }
    _cursor = target;
    return _cursor;
  }

  @override
  int tell() {
    if (_closed) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is closed.',
      );
    }
    return _cursor;
  }

  @override
  void flush() {
    if (_closed) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is closed.',
      );
    }
  }

  @override
  void truncate(int size) {
    if (_closed || !writable) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is not writable.',
      );
    }
    if (size < 0) {
      throw const WasiFsException(WasiFsError.invalid);
    }

    final current = _file.bytes.length;
    if (size < current) {
      _file.bytes.removeRange(size, current);
    } else if (size > current) {
      _file.bytes.addAll(List<int>.filled(size - current, 0));
    }
    if (_cursor > size) {
      _cursor = size;
    }
    final now = _InMemoryFile._nowNs();
    _file.mtimeNs = now;
    _file.ctimeNs = now;
  }

  @override
  void setTimes({int? atimeNs, int? mtimeNs, int? ctimeNs}) {
    if (_closed) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is closed.',
      );
    }
    if (atimeNs != null) {
      _file.atimeNs = atimeNs;
    }
    if (mtimeNs != null) {
      _file.mtimeNs = mtimeNs;
    }
    if (ctimeNs != null) {
      _file.ctimeNs = ctimeNs;
    }
  }

  @override
  void close() {
    _closed = true;
  }
}
