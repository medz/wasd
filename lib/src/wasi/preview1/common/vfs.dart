import 'dart:convert';
import 'dart:typed_data';

final class Preview1VirtualFileSystem {
  Preview1VirtualFileSystem({
    Map<String, String> preopens = const <String, String>{},
    Map<String, Uint8List> files = const <String, Uint8List>{},
    int firstVirtualFd = 64,
  }) : _nextVirtualFd = firstVirtualFd,
       _preopenPathBytesByFd = {
         for (final indexed in preopens.keys.toList().asMap().entries)
           indexed.key + 3: pathBytes(indexed.value),
       },
       _preopenGuestPathsByFd = {
         for (final indexed in preopens.keys.toList().asMap().entries)
           indexed.key + 3: indexed.value,
       },
       _filesByGuestPath = {
         for (final entry in files.entries)
           normalizeGuestPath(entry.key): Preview1VirtualFile(entry.value),
       } {
    _filesByLowerGuestPath = _indexFilesByLowerPath(_filesByGuestPath);
    _filesByBasenameLower = _indexFilesByBasename(
      _filesByGuestPath,
      compact: false,
    );
    _filesByBasenameCompact = _indexFilesByBasename(
      _filesByGuestPath,
      compact: true,
    );
    _virtualDirectoryPaths = _buildVirtualDirectorySet(
      preopenGuestPathsByFd: _preopenGuestPathsByFd,
      filesByGuestPath: _filesByGuestPath,
    );
  }

  final Map<int, Uint8List> _preopenPathBytesByFd;
  final Map<int, String> _preopenGuestPathsByFd;
  final Map<String, Preview1VirtualFile> _filesByGuestPath;
  final Map<int, Preview1VirtualOpenFile> _openFilesByFd =
      <int, Preview1VirtualOpenFile>{};
  final Map<int, String> _openDirectoriesByFd = <int, String>{};

  late final Map<String, Preview1VirtualFile> _filesByLowerGuestPath;
  late final Map<String, Preview1VirtualFile> _filesByBasenameLower;
  late final Map<String, Preview1VirtualFile> _filesByBasenameCompact;
  late final Set<String> _virtualDirectoryPaths;
  int _nextVirtualFd;

  Uint8List? preopenPathBytesForFd(int fd) => _preopenPathBytesByFd[fd];

  String? directoryPathForFd(int fd) =>
      _preopenGuestPathsByFd[fd] ?? _openDirectoriesByFd[fd];

  Preview1VirtualOpenFile? openFileForFd(int fd) => _openFilesByFd[fd];

  bool isPreopenDirectoryFd(int fd) => _preopenGuestPathsByFd.containsKey(fd);

  bool isOpenDirectoryFd(int fd) => _openDirectoriesByFd.containsKey(fd);

  bool isDirectoryFd(int fd) =>
      isPreopenDirectoryFd(fd) || isOpenDirectoryFd(fd);

  bool close(int fd) =>
      _openFilesByFd.remove(fd) != null ||
      _openDirectoriesByFd.remove(fd) != null;

  Preview1VirtualFile? lookupFile(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    final direct = _filesByGuestPath[normalized];
    if (direct != null) {
      return direct;
    }

    final caseInsensitive = _filesByLowerGuestPath[normalized.toLowerCase()];
    if (caseInsensitive != null) {
      return caseInsensitive;
    }

    final basename = basenameOfGuestPath(normalized);
    if (basename.isEmpty) {
      return null;
    }
    final basenameLower = basename.toLowerCase();
    final byBasenameLower = _filesByBasenameLower[basenameLower];
    if (byBasenameLower != null) {
      return byBasenameLower;
    }

    final compactBasename = compactPathToken(basenameLower);
    if (compactBasename.isEmpty) {
      return null;
    }
    return _filesByBasenameCompact[compactBasename];
  }

  bool isDirectoryPath(String guestPath) =>
      _virtualDirectoryPaths.contains(normalizeGuestPath(guestPath));

  Preview1VirtualOpenResult openPath(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    final file = lookupFile(normalized);
    if (file != null) {
      final fd = _nextVirtualFd++;
      _openFilesByFd[fd] = Preview1VirtualOpenFile(file);
      return Preview1VirtualOpenResult.file(fd);
    }

    if (isDirectoryPath(normalized)) {
      final fd = _nextVirtualFd++;
      _openDirectoriesByFd[fd] = normalized;
      return Preview1VirtualOpenResult.directory(fd);
    }

    return const Preview1VirtualOpenResult.missing();
  }
}

final class Preview1VirtualFile {
  Preview1VirtualFile(Uint8List bytes) : _bytes = Uint8List.fromList(bytes);

  Uint8List _bytes;

  Uint8List get bytes => _bytes;

  int get length => _bytes.length;

  int readAtInto(
    Uint8List target,
    int targetStart,
    int length,
    int fileOffset,
  ) {
    final available = _bytes.length - fileOffset;
    if (length <= 0 || fileOffset < 0 || available <= 0) {
      return 0;
    }
    final count = length < available ? length : available;
    target.setRange(targetStart, targetStart + count, _bytes, fileOffset);
    return count;
  }

  int writeAtFrom(
    Uint8List source,
    int sourceStart,
    int length,
    int fileOffset,
  ) {
    if (length <= 0) {
      return 0;
    }
    final end = fileOffset + length;
    if (fileOffset < 0 || end < fileOffset) {
      return 0;
    }
    if (end > _bytes.length) {
      final resized = Uint8List(end);
      resized.setAll(0, _bytes);
      _bytes = resized;
    }
    _bytes.setRange(fileOffset, end, source, sourceStart);
    return length;
  }

  void setLength(int length) {
    if (length == _bytes.length) {
      return;
    }
    final resized = Uint8List(length);
    final copyLength = length < _bytes.length ? length : _bytes.length;
    if (copyLength > 0) {
      resized.setRange(0, copyLength, _bytes);
    }
    _bytes = resized;
  }

  void allocate(int offset, int length) {
    final requiredLength = offset + length;
    if (requiredLength > _bytes.length) {
      setLength(requiredLength);
    }
  }
}

final class Preview1VirtualOpenFile {
  Preview1VirtualOpenFile(this.file);

  Preview1VirtualOpenFile.fromBytes(Uint8List bytes)
    : this(Preview1VirtualFile(bytes));

  final Preview1VirtualFile file;
  int offset = 0;

  Uint8List get bytes => file.bytes;

  int get length => file.length;

  int readInto(Uint8List target, int start, int length) {
    final count = readAtInto(target, start, length, offset);
    offset += count;
    return count;
  }

  int readAtInto(Uint8List target, int start, int length, int fileOffset) =>
      file.readAtInto(target, start, length, fileOffset);

  int writeFrom(Uint8List source, int start, int length) {
    final written = writeAtFrom(source, start, length, offset);
    offset += written;
    return written;
  }

  int writeAtFrom(Uint8List source, int start, int length, int fileOffset) =>
      file.writeAtFrom(source, start, length, fileOffset);

  void setLength(int length) => file.setLength(length);

  void allocate(int offset, int length) => file.allocate(offset, length);
}

enum Preview1VirtualOpenKind { file, directory, missing }

final class Preview1VirtualOpenResult {
  const Preview1VirtualOpenResult._(this.kind, this.fd);

  const Preview1VirtualOpenResult.file(int fd)
    : this._(Preview1VirtualOpenKind.file, fd);

  const Preview1VirtualOpenResult.directory(int fd)
    : this._(Preview1VirtualOpenKind.directory, fd);

  const Preview1VirtualOpenResult.missing()
    : this._(Preview1VirtualOpenKind.missing, null);

  final Preview1VirtualOpenKind kind;
  final int? fd;
}

String? resolveGuestPath({
  required Uint8List bytes,
  required String preopenPath,
  required int pathPtr,
  required int pathLen,
}) {
  if (pathPtr < 0 || pathLen < 0 || pathPtr + pathLen > bytes.length) {
    return null;
  }
  final decoded = utf8.decode(
    bytes.sublist(pathPtr, pathPtr + pathLen),
    allowMalformed: true,
  );
  final nul = decoded.indexOf('\u0000');
  final normalizedPath = nul == -1 ? decoded : decoded.substring(0, nul);
  return joinGuestPath(preopenPath, normalizedPath);
}

String normalizeGuestPath(String path) {
  if (path.isEmpty) {
    return '/';
  }
  final sanitized = path.replaceAll('\\', '/');
  final segments = <String>[];
  for (final segment in sanitized.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty) {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }
  if (segments.isEmpty) {
    return '/';
  }
  return '/${segments.join('/')}';
}

String joinGuestPath(String preopen, String relative) {
  if (relative.startsWith('/')) {
    return normalizeGuestPath(relative);
  }
  final base = normalizeGuestPath(preopen);
  final rel = relative.trim();
  if (rel.isEmpty || rel == '.') {
    return base;
  }
  if (base == '/') {
    return normalizeGuestPath('/$rel');
  }
  return normalizeGuestPath('$base/$rel');
}

String basenameOfGuestPath(String path) {
  final normalized = normalizeGuestPath(path);
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}

String compactPathToken(String value) =>
    value.replaceAll(RegExp(r'[^a-z0-9]'), '');

Uint8List nulTerminated(String value) =>
    Uint8List.fromList(<int>[...utf8.encode(value), 0]);

Uint8List pathBytes(String value) => Uint8List.fromList(utf8.encode(value));

Map<String, Preview1VirtualFile> _indexFilesByLowerPath(
  Map<String, Preview1VirtualFile> filesByGuestPath,
) {
  final indexed = <String, Preview1VirtualFile>{};
  for (final entry in filesByGuestPath.entries) {
    indexed.putIfAbsent(entry.key.toLowerCase(), () => entry.value);
  }
  return indexed;
}

Map<String, Preview1VirtualFile> _indexFilesByBasename(
  Map<String, Preview1VirtualFile> filesByGuestPath, {
  required bool compact,
}) {
  final indexed = <String, Preview1VirtualFile>{};
  for (final entry in filesByGuestPath.entries) {
    final basenameLower = basenameOfGuestPath(entry.key).toLowerCase();
    if (basenameLower.isEmpty) {
      continue;
    }
    final key = compact ? compactPathToken(basenameLower) : basenameLower;
    if (key.isEmpty) {
      continue;
    }
    indexed.putIfAbsent(key, () => entry.value);
  }
  return indexed;
}

Set<String> _buildVirtualDirectorySet({
  required Map<int, String> preopenGuestPathsByFd,
  required Map<String, Preview1VirtualFile> filesByGuestPath,
}) {
  final directories = <String>{'/'};

  void addDirectoryAndParents(String path) {
    var current = normalizeGuestPath(path);
    while (true) {
      directories.add(current);
      if (current == '/') {
        break;
      }
      final slash = current.lastIndexOf('/');
      current = slash <= 0 ? '/' : current.substring(0, slash);
    }
  }

  void addParentDirectories(String filePath) {
    final normalized = normalizeGuestPath(filePath);
    final slash = normalized.lastIndexOf('/');
    if (slash <= 0) {
      directories.add('/');
      return;
    }
    addDirectoryAndParents(normalized.substring(0, slash));
  }

  for (final preopen in preopenGuestPathsByFd.values) {
    addDirectoryAndParents(preopen);
  }
  for (final filePath in filesByGuestPath.keys) {
    addParentDirectories(filePath);
  }
  return directories;
}
