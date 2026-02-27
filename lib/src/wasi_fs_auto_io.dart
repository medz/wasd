import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'wasi_filesystem.dart';

WasiFileSystem createAutoWasiFileSystem({String? ioRootPath}) {
  final root = ioRootPath ?? Directory.current.path;
  return WasiLocalFileSystem(rootPath: root);
}

const bool autoHostIoSupported = true;

final class WasiLocalFileSystem
    implements
        WasiFileSystem,
        WasiMutablePathFileSystem,
        WasiPathTimesFileSystem,
        WasiPathLinkFileSystem,
        WasiPathMetadataFileSystem,
        WasiDirectoryListingFileSystem {
  WasiLocalFileSystem({required String rootPath})
    : _rootDirectory = Directory(rootPath).absolute,
      _rootCanonicalPath = _canonicalizeExistingPath(
        Directory(rootPath).absolute.path,
      );

  final Directory _rootDirectory;
  final String _rootCanonicalPath;

  @override
  WasiFileDescriptor open({
    required String path,
    required bool create,
    required bool truncate,
    required bool read,
    required bool write,
    required bool exclusive,
    required bool followSymlinks,
  }) {
    final guestPath = WasiInMemoryFileSystem.normalizeAbsolutePath(path);
    final hostPath = _resolveHostPath(guestPath);
    if (!followSymlinks && Link(hostPath).existsSync()) {
      throw const WasiFsException(WasiFsError.loop);
    }
    final file = File(hostPath);
    if (Directory(hostPath).existsSync()) {
      throw const WasiFsException(WasiFsError.isDirectory);
    }
    if (!file.parent.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    final exists = file.existsSync();
    if (!exists && !create) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    if (exists && create && exclusive) {
      throw const WasiFsException(WasiFsError.exists);
    }

    if (!exists) {
      file.createSync(recursive: false);
    }
    final initial = exists ? file.readAsBytesSync() : <int>[];
    final descriptor = _LocalFileDescriptor(
      file: file,
      initialBytes: initial,
      readable: read,
      writable: write,
      truncateOnOpen: truncate,
    );
    if (!exists || truncate) {
      descriptor.flush();
    }
    return descriptor;
  }

  @override
  WasiPathStat statPath(String path, {required bool followSymlinks}) {
    final guestPath = WasiInMemoryFileSystem.normalizeAbsolutePath(path);
    final hostPath = _resolveHostPath(guestPath);
    if (!followSymlinks) {
      final link = Link(hostPath);
      if (link.existsSync()) {
        final stat = link.statSync();
        String target;
        try {
          target = link.targetSync();
        } on FileSystemException {
          throw const WasiFsException(WasiFsError.invalid);
        }
        return WasiPathStat(
          fileType: WasiFileType.symbolicLink,
          inode: _inodeFromPath(hostPath),
          size: utf8.encode(target).length,
          atimeNs: _toNs(stat.accessed),
          mtimeNs: _toNs(stat.modified),
          ctimeNs: _toNs(stat.changed),
        );
      }
    }
    if (Directory(hostPath).existsSync()) {
      final stat = Directory(hostPath).statSync();
      return WasiPathStat(
        fileType: WasiFileType.directory,
        inode: _inodeFromPath(hostPath),
        size: 0,
        atimeNs: _toNs(stat.accessed),
        mtimeNs: _toNs(stat.modified),
        ctimeNs: _toNs(stat.changed),
      );
    }

    final file = File(hostPath);
    if (!file.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    final stat = file.statSync();
    return WasiPathStat(
      fileType: WasiFileType.regularFile,
      inode: _inodeFromPath(hostPath),
      size: stat.size,
      atimeNs: _toNs(stat.accessed),
      mtimeNs: _toNs(stat.modified),
      ctimeNs: _toNs(stat.changed),
    );
  }

  @override
  List<WasiDirectoryEntry> readDirectory(String path) {
    final guestPath = WasiInMemoryFileSystem.normalizeAbsolutePath(path);
    final hostPath = _resolveHostPath(guestPath);
    final directory = Directory(hostPath);
    if (!directory.existsSync()) {
      throw const WasiFsException(WasiFsError.notDirectory);
    }

    final entries = <WasiDirectoryEntry>[];
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      if (name.isEmpty) {
        continue;
      }
      if (entity is Directory) {
        entries.add(
          WasiDirectoryEntry(
            name: name,
            fileType: WasiFileType.directory,
            inode: _inodeFromPath(entity.path),
          ),
        );
      } else if (entity is File) {
        entries.add(
          WasiDirectoryEntry(
            name: name,
            fileType: WasiFileType.regularFile,
            inode: _inodeFromPath(entity.path),
          ),
        );
      } else {
        entries.add(
          WasiDirectoryEntry(
            name: name,
            fileType: WasiFileType.unknown,
            inode: _inodeFromPath(entity.path),
          ),
        );
      }
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  void unlinkFile(String path) {
    final guestPath = WasiInMemoryFileSystem.normalizeAbsolutePath(path);
    final hostPath = _resolveHostPath(guestPath);
    final file = File(hostPath);
    if (Directory(hostPath).existsSync()) {
      throw const WasiFsException(WasiFsError.isDirectory);
    }
    if (!file.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    file.deleteSync();
  }

  @override
  void rename({required String sourcePath, required String destinationPath}) {
    final sourceGuest = WasiInMemoryFileSystem.normalizeAbsolutePath(
      sourcePath,
    );
    final destinationGuest = WasiInMemoryFileSystem.normalizeAbsolutePath(
      destinationPath,
    );
    if (sourceGuest == destinationGuest) {
      return;
    }
    final sourceHost = _resolveHostPath(sourceGuest);
    final destinationHost = _resolveHostPath(destinationGuest);
    final sourceType = FileSystemEntity.typeSync(
      sourceHost,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    final destinationParent = File(destinationHost).parent;
    if (!destinationParent.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    final destinationType = FileSystemEntity.typeSync(
      destinationHost,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.directory) {
      if (destinationType == FileSystemEntityType.file ||
          destinationType == FileSystemEntityType.link) {
        throw const WasiFsException(WasiFsError.notDirectory);
      }
      if (destinationType == FileSystemEntityType.directory) {
        final destinationDirectory = Directory(destinationHost);
        if (destinationDirectory.listSync(followLinks: false).isNotEmpty) {
          throw const WasiFsException(WasiFsError.directoryNotEmpty);
        }
        destinationDirectory.deleteSync(recursive: false);
      }
      Directory(sourceHost).renameSync(destinationHost);
      return;
    }

    if (destinationType == FileSystemEntityType.directory) {
      throw const WasiFsException(WasiFsError.isDirectory);
    }
    if (destinationType == FileSystemEntityType.file) {
      File(destinationHost).deleteSync();
    } else if (destinationType == FileSystemEntityType.link) {
      Link(destinationHost).deleteSync();
    }

    if (sourceType == FileSystemEntityType.link) {
      Link(sourceHost).renameSync(destinationHost);
      return;
    }
    File(sourceHost).renameSync(destinationHost);
  }

  @override
  void createDirectory(String path) {
    final guestPath = WasiInMemoryFileSystem.normalizeAbsolutePath(path);
    if (guestPath == '/') {
      throw const WasiFsException(WasiFsError.exists);
    }
    final hostPath = _resolveHostPath(guestPath);
    final directory = Directory(hostPath);
    if (directory.existsSync() || File(hostPath).existsSync()) {
      throw const WasiFsException(WasiFsError.exists);
    }
    final parent = directory.parent;
    if (!parent.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    directory.createSync(recursive: false);
  }

  @override
  void removeDirectory(String path) {
    final guestPath = WasiInMemoryFileSystem.normalizeAbsolutePath(path);
    if (guestPath == '/') {
      throw const WasiFsException(WasiFsError.permissionDenied);
    }
    final hostPath = _resolveHostPath(guestPath);
    final directory = Directory(hostPath);
    if (!directory.existsSync()) {
      throw const WasiFsException(WasiFsError.notDirectory);
    }
    if (directory.listSync(followLinks: false).isNotEmpty) {
      throw const WasiFsException(WasiFsError.directoryNotEmpty);
    }
    directory.deleteSync(recursive: false);
  }

  @override
  void setPathTimes({
    required String path,
    int? atimeNs,
    int? mtimeNs,
    int? ctimeNs,
    required bool followSymlinks,
  }) {
    final guestPath = WasiInMemoryFileSystem.normalizeAbsolutePath(path);
    final hostPath = _resolveHostPath(guestPath);
    final link = Link(hostPath);
    if (!followSymlinks && link.existsSync()) {
      throw const WasiFsException(
        WasiFsError.notSupported,
        'Symlink timestamp updates are not supported by this backend.',
      );
    }
    final file = File(hostPath);
    final directory = Directory(hostPath);
    if (!file.existsSync() && !directory.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    final effectiveMtimeNs = mtimeNs;
    if (effectiveMtimeNs != null) {
      final time = DateTime.fromMicrosecondsSinceEpoch(
        effectiveMtimeNs ~/ 1000,
      );
      if (file.existsSync()) {
        file.setLastModifiedSync(time);
      } else {
        throw const WasiFsException(
          WasiFsError.notSupported,
          'Directory timestamps are not supported by this backend.',
        );
      }
    }

    if (atimeNs != null || ctimeNs != null) {
      // No portable dart:io API for atime/ctime updates.
      throw const WasiFsException(
        WasiFsError.notSupported,
        'atime/ctime updates are not supported by this backend.',
      );
    }
  }

  @override
  void link({
    required String sourcePath,
    required String destinationPath,
    required bool followSymlinks,
  }) {
    final sourceGuest = WasiInMemoryFileSystem.normalizeAbsolutePath(
      sourcePath,
    );
    final destinationGuest = WasiInMemoryFileSystem.normalizeAbsolutePath(
      destinationPath,
    );
    final sourceHost = _resolveHostPath(sourceGuest);
    final destinationHost = _resolveHostPath(destinationGuest);
    final sourceType = FileSystemEntity.typeSync(
      sourceHost,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    if (sourceType == FileSystemEntityType.directory) {
      throw const WasiFsException(WasiFsError.isDirectory);
    }
    final destination = File(destinationHost);
    if (destination.existsSync() || Directory(destinationHost).existsSync()) {
      throw const WasiFsException(WasiFsError.exists);
    }
    if (!destination.parent.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }

    if (sourceType == FileSystemEntityType.link && !followSymlinks) {
      final sourceLink = Link(sourceHost);
      String target;
      try {
        target = sourceLink.targetSync();
      } on FileSystemException {
        throw const WasiFsException(WasiFsError.invalid);
      }
      Link(destinationHost).createSync(target, recursive: false);
      return;
    }

    final bytes = File(sourceHost).readAsBytesSync();
    destination.writeAsBytesSync(bytes, flush: true);
  }

  @override
  void symlink({required String targetPath, required String linkPath}) {
    final linkGuest = WasiInMemoryFileSystem.normalizeAbsolutePath(linkPath);
    final linkHost = _resolveHostPath(linkGuest);
    final link = Link(linkHost);
    if (link.existsSync() ||
        File(linkHost).existsSync() ||
        Directory(linkHost).existsSync()) {
      throw const WasiFsException(WasiFsError.exists);
    }
    if (!File(linkHost).parent.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    link.createSync(targetPath, recursive: false);
  }

  @override
  String readlink(String path) {
    final guestPath = WasiInMemoryFileSystem.normalizeAbsolutePath(path);
    final hostPath = _resolveHostPath(guestPath);
    final link = Link(hostPath);
    if (!link.existsSync()) {
      throw const WasiFsException(WasiFsError.notFound);
    }
    try {
      return link.targetSync();
    } on FileSystemException {
      throw const WasiFsException(WasiFsError.invalid);
    }
  }

  String _resolveHostPath(String guestAbsolutePath) {
    final normalized = WasiInMemoryFileSystem.normalizeAbsolutePath(
      guestAbsolutePath,
    );
    final root = _rootDirectory.path;
    final hostPath = normalized == '/'
        ? root
        : '$root${Platform.pathSeparator}${normalized.substring(1).replaceAll('/', Platform.pathSeparator)}';
    _assertWithinSandbox(hostPath);
    return hostPath;
  }

  void _assertWithinSandbox(String hostPath) {
    final entityType = FileSystemEntity.typeSync(hostPath, followLinks: false);
    if (entityType != FileSystemEntityType.notFound) {
      final canonical = _canonicalizeExistingPath(hostPath);
      if (!_isWithinRoot(canonical)) {
        throw const WasiFsException(WasiFsError.permissionDenied);
      }
      return;
    }

    final parentCanonical = _canonicalizeExistingPath(
      File(hostPath).parent.path,
    );
    if (!_isWithinRoot(parentCanonical)) {
      throw const WasiFsException(WasiFsError.permissionDenied);
    }
  }

  bool _isWithinRoot(String canonicalPath) {
    if (canonicalPath == _rootCanonicalPath) {
      return true;
    }
    return canonicalPath.startsWith(
      '$_rootCanonicalPath${Platform.pathSeparator}',
    );
  }

  static String _canonicalizeExistingPath(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      try {
        return Directory(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        return Directory(path).absolute.path;
      }
    }
  }

  static int _toNs(DateTime dt) => dt.microsecondsSinceEpoch * 1000;

  static int _inodeFromPath(String path) {
    var hash = 1469598103934665603;
    for (final codeUnit in path.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 1099511628211) & 0x7fffffffffffffff;
    }
    return hash;
  }
}

final class _LocalFileDescriptor implements WasiFileDescriptor {
  _LocalFileDescriptor({
    required File file,
    required List<int> initialBytes,
    required this.readable,
    required this.writable,
    required bool truncateOnOpen,
  }) : _file = file,
       _buffer = List<int>.from(initialBytes),
       _inode = WasiLocalFileSystem._inodeFromPath(file.absolute.path) {
    final stat = file.statSync();
    _atimeNs = WasiLocalFileSystem._toNs(stat.accessed);
    _mtimeNs = WasiLocalFileSystem._toNs(stat.modified);
    _ctimeNs = WasiLocalFileSystem._toNs(stat.changed);
    if (truncateOnOpen) {
      _buffer.clear();
      _mtimeNs = _nowNs();
      _ctimeNs = _mtimeNs;
      _dirty = true;
    }
  }

  final File _file;
  final List<int> _buffer;
  final int _inode;
  @override
  final bool readable;
  @override
  final bool writable;

  int _cursor = 0;
  bool _closed = false;
  bool _dirty = false;
  late int _atimeNs;
  late int _mtimeNs;
  late int _ctimeNs;

  @override
  int get inode => _inode;

  @override
  int get size => _buffer.length;

  @override
  int get atimeNs => _atimeNs;

  @override
  int get mtimeNs => _mtimeNs;

  @override
  int get ctimeNs => _ctimeNs;

  @override
  int write(Uint8List bytes) {
    _ensureWritable();
    if (bytes.isEmpty) {
      return 0;
    }

    final requiredLength = _cursor + bytes.length;
    while (_buffer.length < requiredLength) {
      _buffer.add(0);
    }
    for (var i = 0; i < bytes.length; i++) {
      _buffer[_cursor + i] = bytes[i];
    }
    _cursor += bytes.length;
    _dirty = true;
    _mtimeNs = _nowNs();
    _ctimeNs = _mtimeNs;
    flush();
    return bytes.length;
  }

  @override
  Uint8List read(int maxBytes) {
    _ensureReadable();
    if (maxBytes <= 0) {
      return Uint8List(0);
    }

    final available = _buffer.length - _cursor;
    if (available <= 0) {
      return Uint8List(0);
    }
    final count = available < maxBytes ? available : maxBytes;
    final out = Uint8List.fromList(_buffer.sublist(_cursor, _cursor + count));
    _cursor += count;
    _atimeNs = _nowNs();
    return out;
  }

  @override
  int seek(int offset, int whence) {
    _ensureOpen();
    final base = switch (whence) {
      0 => 0,
      1 => _cursor,
      2 => _buffer.length,
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
    _ensureOpen();
    return _cursor;
  }

  @override
  void flush() {
    _ensureOpen();
    if (!_dirty) {
      return;
    }
    _file.writeAsBytesSync(_buffer, flush: true);
    _dirty = false;
  }

  @override
  void truncate(int size) {
    _ensureWritable();
    if (size < 0) {
      throw const WasiFsException(WasiFsError.invalid);
    }

    final current = _buffer.length;
    if (size < current) {
      _buffer.removeRange(size, current);
    } else if (size > current) {
      _buffer.addAll(List<int>.filled(size - current, 0));
    }
    if (_cursor > size) {
      _cursor = size;
    }
    _dirty = true;
    _mtimeNs = _nowNs();
    _ctimeNs = _mtimeNs;
    flush();
  }

  @override
  void setTimes({int? atimeNs, int? mtimeNs, int? ctimeNs}) {
    _ensureOpen();
    if (atimeNs != null) {
      _atimeNs = atimeNs;
    }
    if (mtimeNs != null) {
      _mtimeNs = mtimeNs;
      _file.setLastModifiedSync(
        DateTime.fromMicrosecondsSinceEpoch(mtimeNs ~/ 1000),
      );
    }
    if (ctimeNs != null) {
      _ctimeNs = ctimeNs;
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    flush();
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is closed.',
      );
    }
  }

  void _ensureReadable() {
    _ensureOpen();
    if (!readable) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is not readable.',
      );
    }
  }

  void _ensureWritable() {
    _ensureOpen();
    if (!writable) {
      throw const WasiFsException(
        WasiFsError.permissionDenied,
        'File descriptor is not writable.',
      );
    }
  }

  static int _nowNs() => DateTime.now().microsecondsSinceEpoch * 1000;
}
