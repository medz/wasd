import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'constants.dart';

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
       _preopenDirectoryFlagsByFd = {
         for (final indexed in preopens.keys.toList().asMap().entries)
           indexed.key + 3: 0,
       },
       _filesByGuestPath = {
         for (final entry in files.entries)
           normalizeGuestPath(entry.key): Preview1VirtualFile(entry.value),
       },
       _symlinksByGuestPath = <String, Preview1VirtualSymlink>{} {
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
    _directoryMetadataByGuestPath = {
      for (final path in _virtualDirectoryPaths)
        path: Preview1VirtualNodeMetadata(),
    };
    _directoryEntriesByGuestPath = _buildDirectoryEntriesByPath(
      directories: _virtualDirectoryPaths,
      filesByGuestPath: _filesByGuestPath,
      symlinksByGuestPath: _symlinksByGuestPath,
    );
  }

  final Map<int, Uint8List> _preopenPathBytesByFd;
  final Map<int, String> _preopenGuestPathsByFd;
  final Map<int, int> _preopenDirectoryFlagsByFd;
  final Map<String, Preview1VirtualFile> _filesByGuestPath;
  final Map<String, Preview1VirtualSymlink> _symlinksByGuestPath;
  final Map<int, Preview1VirtualOpenFile> _openFilesByFd =
      <int, Preview1VirtualOpenFile>{};
  final Map<int, String> _openDirectoriesByFd = <int, String>{};
  final Map<int, int> _openDirectoryFlagsByFd = <int, int>{};

  late Map<String, Preview1VirtualFile> _filesByLowerGuestPath;
  late Map<String, Preview1VirtualFile> _filesByBasenameLower;
  late Map<String, Preview1VirtualFile> _filesByBasenameCompact;
  late final Set<String> _virtualDirectoryPaths;
  late Map<String, Preview1VirtualNodeMetadata> _directoryMetadataByGuestPath;
  late Map<String, List<Preview1DirectoryEntry>> _directoryEntriesByGuestPath;
  int _nextVirtualFd;

  Uint8List? preopenPathBytesForFd(int fd) => _preopenPathBytesByFd[fd];

  String? directoryPathForFd(int fd) =>
      _preopenGuestPathsByFd[fd] ?? _openDirectoriesByFd[fd];

  Preview1VirtualOpenFile? openFileForFd(int fd) => _openFilesByFd[fd];

  int? descriptorFlagsForFd(int fd) {
    final opened = openFileForFd(fd);
    if (opened != null) {
      return opened.descriptorFlags;
    }
    return _openDirectoryFlagsByFd[fd] ?? _preopenDirectoryFlagsByFd[fd];
  }

  bool setDescriptorFlags(int fd, int flags) {
    final opened = openFileForFd(fd);
    if (opened != null) {
      opened.descriptorFlags = flags;
      return true;
    }
    if (_openDirectoriesByFd.containsKey(fd)) {
      _openDirectoryFlagsByFd[fd] = flags;
      return true;
    }
    if (_preopenDirectoryFlagsByFd.containsKey(fd)) {
      _preopenDirectoryFlagsByFd[fd] = flags;
      return true;
    }
    return false;
  }

  Preview1FdRenumberResult renumberDescriptor({
    required int fromFd,
    required int toFd,
  }) {
    if (fromFd < 0 || toFd < 0) {
      return Preview1FdRenumberResult.invalid;
    }
    if (!_hasDescriptor(fromFd)) {
      return Preview1FdRenumberResult.badf;
    }
    if (fromFd == toFd) {
      return Preview1FdRenumberResult.success;
    }

    final openFile = _openFilesByFd.remove(fromFd);
    if (openFile != null) {
      _closeDescriptor(toFd);
      _openFilesByFd[toFd] = openFile;
      _advanceNextVirtualFdPast(toFd);
      return Preview1FdRenumberResult.success;
    }

    final openDirectory = _openDirectoriesByFd.remove(fromFd);
    if (openDirectory != null) {
      final flags = _openDirectoryFlagsByFd.remove(fromFd) ?? 0;
      _closeDescriptor(toFd);
      _openDirectoriesByFd[toFd] = openDirectory;
      _openDirectoryFlagsByFd[toFd] = flags;
      _advanceNextVirtualFdPast(toFd);
      return Preview1FdRenumberResult.success;
    }

    final preopenDirectory = _preopenGuestPathsByFd.remove(fromFd);
    if (preopenDirectory != null) {
      final pathBytes = _preopenPathBytesByFd.remove(fromFd);
      final flags = _preopenDirectoryFlagsByFd.remove(fromFd) ?? 0;
      _closeDescriptor(toFd);
      _preopenGuestPathsByFd[toFd] = preopenDirectory;
      if (pathBytes != null) {
        _preopenPathBytesByFd[toFd] = pathBytes;
      }
      _preopenDirectoryFlagsByFd[toFd] = flags;
      _advanceNextVirtualFdPast(toFd);
      return Preview1FdRenumberResult.success;
    }

    return Preview1FdRenumberResult.badf;
  }

  bool isPreopenDirectoryFd(int fd) => _preopenGuestPathsByFd.containsKey(fd);

  bool isOpenDirectoryFd(int fd) => _openDirectoriesByFd.containsKey(fd);

  bool isDirectoryFd(int fd) =>
      isPreopenDirectoryFd(fd) || isOpenDirectoryFd(fd);

  List<Preview1DirectoryEntry>? directoryEntriesForFd(int fd) {
    final directoryPath = directoryPathForFd(fd);
    if (directoryPath == null) {
      return null;
    }
    return _directoryEntriesByGuestPath[normalizeGuestPath(directoryPath)] ??
        const <Preview1DirectoryEntry>[];
  }

  Preview1VirtualNodeMetadata? metadataForFd(int fd) {
    final opened = openFileForFd(fd);
    if (opened != null) {
      return opened.metadata;
    }
    final directoryPath = directoryPathForFd(fd);
    if (directoryPath == null) {
      return null;
    }
    return _directoryMetadataByGuestPath[normalizeGuestPath(directoryPath)];
  }

  Preview1VirtualNodeMetadata? metadataForPath(String guestPath) {
    return pathEntry(guestPath)?.metadata;
  }

  Preview1VirtualSymlink? symlinkForPath(String guestPath) {
    return _symlinksByGuestPath[normalizeGuestPath(guestPath)];
  }

  Preview1VirtualPathEntry? pathEntry(
    String guestPath, {
    bool followSymlinks = false,
  }) {
    final resolved = followSymlinks
        ? resolveSymlinkPath(guestPath)
        : normalizeGuestPath(guestPath);
    if (resolved == null) {
      return null;
    }

    final file = lookupFile(resolved);
    if (file != null) {
      return Preview1VirtualPathEntry(
        kind: Preview1VirtualPathEntryKind.file,
        metadata: file.metadata,
        size: file.length,
      );
    }

    final directoryMetadata = _directoryMetadataByGuestPath[resolved];
    if (directoryMetadata != null) {
      return Preview1VirtualPathEntry(
        kind: Preview1VirtualPathEntryKind.directory,
        metadata: directoryMetadata,
      );
    }

    final symlink = _symlinksByGuestPath[resolved];
    if (symlink != null) {
      return Preview1VirtualPathEntry(
        kind: Preview1VirtualPathEntryKind.symlink,
        metadata: symlink.metadata,
        size: symlink.targetBytes.length,
      );
    }

    return null;
  }

  String? resolveSymlinkPath(String guestPath, {int maxDepth = 16}) {
    var current = normalizeGuestPath(guestPath);
    for (var depth = 0; depth < maxDepth; depth++) {
      final symlink = _symlinksByGuestPath[current];
      if (symlink == null) {
        return current;
      }
      current = normalizeGuestPath(
        symlink.target.startsWith('/')
            ? symlink.target
            : joinGuestPath(dirnameOfGuestPath(current), symlink.target),
      );
    }
    return null;
  }

  bool close(int fd) {
    if (_openFilesByFd.remove(fd) != null) {
      return true;
    }
    if (_openDirectoriesByFd.remove(fd) != null) {
      _openDirectoryFlagsByFd.remove(fd);
      return true;
    }
    return false;
  }

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

  Preview1PathMutationResult createDirectory(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    if (normalized == '/' ||
        _filesByGuestPath.containsKey(normalized) ||
        _symlinksByGuestPath.containsKey(normalized) ||
        _virtualDirectoryPaths.contains(normalized)) {
      return Preview1PathMutationResult.exists;
    }

    final parent = dirnameOfGuestPath(normalized);
    if (_filesByGuestPath.containsKey(parent) ||
        _symlinksByGuestPath.containsKey(parent)) {
      return Preview1PathMutationResult.notDirectory;
    }
    if (!_virtualDirectoryPaths.contains(parent)) {
      return Preview1PathMutationResult.noEntry;
    }

    _virtualDirectoryPaths.add(normalized);
    _directoryMetadataByGuestPath[normalized] = Preview1VirtualNodeMetadata();
    _rebuildDirectoryEntries();
    return Preview1PathMutationResult.success;
  }

  Preview1PathMutationResult removeDirectory(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    if (_filesByGuestPath.containsKey(normalized) ||
        _symlinksByGuestPath.containsKey(normalized)) {
      return Preview1PathMutationResult.notDirectory;
    }
    if (!_virtualDirectoryPaths.contains(normalized)) {
      return Preview1PathMutationResult.noEntry;
    }
    if (normalized == '/' || _preopenGuestPathsByFd.containsValue(normalized)) {
      return Preview1PathMutationResult.notEmpty;
    }

    final childPrefix = '$normalized/';
    final hasFileChildren = _filesByGuestPath.keys.any(
      (path) => path.startsWith(childPrefix),
    );
    final hasSymlinkChildren = _symlinksByGuestPath.keys.any(
      (path) => path.startsWith(childPrefix),
    );
    final hasDirectoryChildren = _virtualDirectoryPaths.any(
      (path) => path != normalized && path.startsWith(childPrefix),
    );
    if (hasFileChildren || hasSymlinkChildren || hasDirectoryChildren) {
      return Preview1PathMutationResult.notEmpty;
    }

    _virtualDirectoryPaths.remove(normalized);
    _directoryMetadataByGuestPath.remove(normalized);
    _openDirectoriesByFd.removeWhere((_, path) => path == normalized);
    _openDirectoryFlagsByFd.removeWhere(
      (fd, _) => !_openDirectoriesByFd.containsKey(fd),
    );
    _rebuildDirectoryEntries();
    return Preview1PathMutationResult.success;
  }

  Preview1PathMutationResult unlinkFile(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    if (_virtualDirectoryPaths.contains(normalized)) {
      return Preview1PathMutationResult.isDirectory;
    }
    if (_symlinksByGuestPath.remove(normalized) != null) {
      _rebuildDirectoryEntries();
      return Preview1PathMutationResult.success;
    }
    if (_filesByGuestPath.remove(normalized) == null) {
      return Preview1PathMutationResult.noEntry;
    }

    _rebuildFileIndexes();
    _rebuildDirectoryEntries();
    return Preview1PathMutationResult.success;
  }

  Preview1PathMutationResult renamePath({
    required String oldPath,
    required String newPath,
  }) {
    final oldNormalized = normalizeGuestPath(oldPath);
    final newNormalized = normalizeGuestPath(newPath);
    final newParent = dirnameOfGuestPath(newNormalized);
    if (_filesByGuestPath.containsKey(newParent) ||
        _symlinksByGuestPath.containsKey(newParent)) {
      return Preview1PathMutationResult.notDirectory;
    }
    if (!_virtualDirectoryPaths.contains(newParent)) {
      return Preview1PathMutationResult.noEntry;
    }

    final oldFile = _filesByGuestPath[oldNormalized];
    if (oldFile != null) {
      if (_virtualDirectoryPaths.contains(newNormalized)) {
        return Preview1PathMutationResult.isDirectory;
      }
      if (_symlinksByGuestPath.containsKey(newNormalized)) {
        return Preview1PathMutationResult.exists;
      }
      _filesByGuestPath.remove(oldNormalized);
      _filesByGuestPath[newNormalized] = oldFile;
      _rebuildFileIndexes();
      _rebuildDirectoryEntries();
      return Preview1PathMutationResult.success;
    }

    final oldSymlink = _symlinksByGuestPath[oldNormalized];
    if (oldSymlink != null) {
      if (_filesByGuestPath.containsKey(newNormalized) ||
          _symlinksByGuestPath.containsKey(newNormalized) ||
          _virtualDirectoryPaths.contains(newNormalized)) {
        return Preview1PathMutationResult.exists;
      }
      _symlinksByGuestPath.remove(oldNormalized);
      _symlinksByGuestPath[newNormalized] = oldSymlink;
      _rebuildDirectoryEntries();
      return Preview1PathMutationResult.success;
    }

    if (!_virtualDirectoryPaths.contains(oldNormalized)) {
      return Preview1PathMutationResult.noEntry;
    }
    if (oldNormalized == '/' ||
        _preopenGuestPathsByFd.containsValue(oldNormalized) ||
        _isChildPath(newNormalized, oldNormalized)) {
      return Preview1PathMutationResult.invalid;
    }
    if (_filesByGuestPath.containsKey(newNormalized) ||
        _symlinksByGuestPath.containsKey(newNormalized)) {
      return Preview1PathMutationResult.notDirectory;
    }
    if (_virtualDirectoryPaths.contains(newNormalized)) {
      return Preview1PathMutationResult.exists;
    }

    _renameDirectory(oldNormalized, newNormalized);
    return Preview1PathMutationResult.success;
  }

  Preview1PathMutationResult linkPath({
    required String oldPath,
    required String newPath,
  }) {
    final oldNormalized = normalizeGuestPath(oldPath);
    final newNormalized = normalizeGuestPath(newPath);
    final newParent = dirnameOfGuestPath(newNormalized);
    if (_filesByGuestPath.containsKey(newParent) ||
        _symlinksByGuestPath.containsKey(newParent)) {
      return Preview1PathMutationResult.notDirectory;
    }
    if (!_virtualDirectoryPaths.contains(newParent)) {
      return Preview1PathMutationResult.noEntry;
    }
    if (_filesByGuestPath.containsKey(newNormalized) ||
        _symlinksByGuestPath.containsKey(newNormalized) ||
        _virtualDirectoryPaths.contains(newNormalized)) {
      return Preview1PathMutationResult.exists;
    }

    final oldFile = _filesByGuestPath[oldNormalized];
    if (oldFile == null) {
      if (_virtualDirectoryPaths.contains(oldNormalized)) {
        return Preview1PathMutationResult.isDirectory;
      }
      return Preview1PathMutationResult.noEntry;
    }

    _filesByGuestPath[newNormalized] = oldFile;
    _rebuildFileIndexes();
    _rebuildDirectoryEntries();
    return Preview1PathMutationResult.success;
  }

  Preview1PathMutationResult createSymlink({
    required String target,
    required String linkPath,
  }) {
    final normalized = normalizeGuestPath(linkPath);
    if (normalized == '/' ||
        _filesByGuestPath.containsKey(normalized) ||
        _symlinksByGuestPath.containsKey(normalized) ||
        _virtualDirectoryPaths.contains(normalized)) {
      return Preview1PathMutationResult.exists;
    }

    final parent = dirnameOfGuestPath(normalized);
    if (_filesByGuestPath.containsKey(parent) ||
        _symlinksByGuestPath.containsKey(parent)) {
      return Preview1PathMutationResult.notDirectory;
    }
    if (!_virtualDirectoryPaths.contains(parent)) {
      return Preview1PathMutationResult.noEntry;
    }

    _symlinksByGuestPath[normalized] = Preview1VirtualSymlink(target);
    _rebuildDirectoryEntries();
    return Preview1PathMutationResult.success;
  }

  Preview1VirtualOpenResult openPath(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    final file = lookupFile(normalized);
    if (file != null) {
      final fd = _allocateVirtualFd();
      _openFilesByFd[fd] = Preview1VirtualOpenFile(file);
      return Preview1VirtualOpenResult.file(fd);
    }

    if (isDirectoryPath(normalized)) {
      final fd = _allocateVirtualFd();
      _openDirectoriesByFd[fd] = normalized;
      _openDirectoryFlagsByFd[fd] = 0;
      return Preview1VirtualOpenResult.directory(fd);
    }

    return const Preview1VirtualOpenResult.missing();
  }

  void _renameDirectory(String oldPath, String newPath) {
    final renamedDirectories = <String>{};
    for (final path in _virtualDirectoryPaths) {
      if (path == oldPath || _isChildPath(path, oldPath)) {
        renamedDirectories.add('$newPath${path.substring(oldPath.length)}');
      }
    }
    _virtualDirectoryPaths.removeWhere(
      (path) => path == oldPath || _isChildPath(path, oldPath),
    );
    _virtualDirectoryPaths.addAll(renamedDirectories);

    final renamedDirectoryMetadata = <String, Preview1VirtualNodeMetadata>{};
    _directoryMetadataByGuestPath.removeWhere((path, metadata) {
      if (path == oldPath || _isChildPath(path, oldPath)) {
        renamedDirectoryMetadata['$newPath${path.substring(oldPath.length)}'] =
            metadata;
        return true;
      }
      return false;
    });
    _directoryMetadataByGuestPath.addAll(renamedDirectoryMetadata);

    final renamedFiles = <String, Preview1VirtualFile>{};
    _filesByGuestPath.removeWhere((path, file) {
      if (!_isChildPath(path, oldPath)) {
        return false;
      }
      renamedFiles['$newPath${path.substring(oldPath.length)}'] = file;
      return true;
    });
    _filesByGuestPath.addAll(renamedFiles);

    final renamedSymlinks = <String, Preview1VirtualSymlink>{};
    _symlinksByGuestPath.removeWhere((path, symlink) {
      if (!_isChildPath(path, oldPath)) {
        return false;
      }
      renamedSymlinks['$newPath${path.substring(oldPath.length)}'] = symlink;
      return true;
    });
    _symlinksByGuestPath.addAll(renamedSymlinks);

    for (final entry in _openDirectoriesByFd.entries.toList()) {
      final path = entry.value;
      if (path == oldPath || _isChildPath(path, oldPath)) {
        _openDirectoriesByFd[entry.key] =
            '$newPath${path.substring(oldPath.length)}';
      }
    }
    _rebuildFileIndexes();
    _rebuildDirectoryEntries();
  }

  void _rebuildFileIndexes() {
    _filesByLowerGuestPath = _indexFilesByLowerPath(_filesByGuestPath);
    _filesByBasenameLower = _indexFilesByBasename(
      _filesByGuestPath,
      compact: false,
    );
    _filesByBasenameCompact = _indexFilesByBasename(
      _filesByGuestPath,
      compact: true,
    );
  }

  void _rebuildDirectoryEntries() {
    _directoryEntriesByGuestPath = _buildDirectoryEntriesByPath(
      directories: _virtualDirectoryPaths,
      filesByGuestPath: _filesByGuestPath,
      symlinksByGuestPath: _symlinksByGuestPath,
    );
  }

  int _allocateVirtualFd() {
    while (_hasDescriptor(_nextVirtualFd)) {
      _nextVirtualFd++;
    }
    return _nextVirtualFd++;
  }

  void _advanceNextVirtualFdPast(int fd) {
    if (fd >= _nextVirtualFd) {
      _nextVirtualFd = fd + 1;
    }
  }

  bool _hasDescriptor(int fd) =>
      _openFilesByFd.containsKey(fd) ||
      _openDirectoriesByFd.containsKey(fd) ||
      _preopenGuestPathsByFd.containsKey(fd);

  void _closeDescriptor(int fd) {
    _openFilesByFd.remove(fd);
    _openDirectoriesByFd.remove(fd);
    _openDirectoryFlagsByFd.remove(fd);
    _preopenPathBytesByFd.remove(fd);
    _preopenGuestPathsByFd.remove(fd);
    _preopenDirectoryFlagsByFd.remove(fd);
  }
}

final class Preview1DirectoryEntry {
  Preview1DirectoryEntry({required this.name, required this.fileType})
    : nameBytes = pathBytes(name);

  final String name;
  final Uint8List nameBytes;
  final int fileType;
}

final class Preview1VirtualNodeMetadata {
  int accessTimeNanos = 0;
  int modificationTimeNanos = 0;
}

enum Preview1VirtualPathEntryKind { file, directory, symlink }

final class Preview1VirtualPathEntry {
  const Preview1VirtualPathEntry({
    required this.kind,
    required this.metadata,
    this.size = 0,
  });

  final Preview1VirtualPathEntryKind kind;
  final Preview1VirtualNodeMetadata metadata;
  final int size;

  int get fileType => switch (kind) {
    Preview1VirtualPathEntryKind.file => filetypeRegularFile,
    Preview1VirtualPathEntryKind.directory => filetypeDirectory,
    Preview1VirtualPathEntryKind.symlink => filetypeSymbolicLink,
  };
}

int writeDirectoryEntries({
  required List<Preview1DirectoryEntry> entries,
  required Uint8List bytes,
  required ByteData data,
  required int bufferPtr,
  required int bufferLength,
  required int cookie,
}) {
  final startIndex = cookie <= 0 ? 0 : math.min(cookie, entries.length);
  var written = 0;
  for (var index = startIndex; index < entries.length; index++) {
    final remaining = bufferLength - written;
    if (remaining < direntSize) {
      break;
    }

    final entry = entries[index];
    final entryPtr = bufferPtr + written;
    bytes.fillRange(entryPtr, entryPtr + direntSize, 0);
    _setUint64(data, entryPtr + direntNextOffset, index + 1);
    _setUint64(data, entryPtr + direntInodeOffset, 0);
    data.setUint32(
      entryPtr + direntNameLengthOffset,
      entry.nameBytes.length,
      Endian.little,
    );
    bytes[entryPtr + direntTypeOffset] = entry.fileType;

    final namePtr = entryPtr + direntSize;
    final nameBytesToWrite = math.min(
      entry.nameBytes.length,
      remaining - direntSize,
    );
    if (nameBytesToWrite > 0) {
      bytes.setRange(namePtr, namePtr + nameBytesToWrite, entry.nameBytes);
    }
    written += direntSize + nameBytesToWrite;
    if (nameBytesToWrite < entry.nameBytes.length) {
      break;
    }
  }
  return written;
}

final class Preview1VirtualFile {
  Preview1VirtualFile(Uint8List bytes) : _bytes = Uint8List.fromList(bytes);

  Uint8List _bytes;
  final Preview1VirtualNodeMetadata metadata = Preview1VirtualNodeMetadata();

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

final class Preview1VirtualSymlink {
  Preview1VirtualSymlink(this.target) : targetBytes = pathBytes(target);

  final String target;
  final Uint8List targetBytes;
  final Preview1VirtualNodeMetadata metadata = Preview1VirtualNodeMetadata();
}

final class Preview1VirtualOpenFile {
  Preview1VirtualOpenFile(this.file);

  Preview1VirtualOpenFile.fromBytes(Uint8List bytes)
    : this(Preview1VirtualFile(bytes));

  final Preview1VirtualFile file;
  int offset = 0;
  int descriptorFlags = 0;

  Uint8List get bytes => file.bytes;

  int get length => file.length;

  Preview1VirtualNodeMetadata get metadata => file.metadata;

  int readInto(Uint8List target, int start, int length) {
    final count = readAtInto(target, start, length, offset);
    offset += count;
    return count;
  }

  int readAtInto(Uint8List target, int start, int length, int fileOffset) =>
      file.readAtInto(target, start, length, fileOffset);

  int writeFrom(Uint8List source, int start, int length) {
    final fileOffset = (descriptorFlags & fdflagAppend) == 0
        ? offset
        : file.length;
    final written = writeAtFrom(source, start, length, fileOffset);
    offset = fileOffset + written;
    return written;
  }

  int writeAtFrom(Uint8List source, int start, int length, int fileOffset) =>
      file.writeAtFrom(source, start, length, fileOffset);

  void setLength(int length) => file.setLength(length);

  void allocate(int offset, int length) => file.allocate(offset, length);
}

enum Preview1VirtualOpenKind { file, directory, missing }

enum Preview1PathMutationResult {
  success,
  invalid,
  noEntry,
  exists,
  isDirectory,
  notDirectory,
  notEmpty,
}

enum Preview1FdRenumberResult { success, invalid, badf }

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

String dirnameOfGuestPath(String path) {
  final normalized = normalizeGuestPath(path);
  if (normalized == '/') {
    return '/';
  }
  final slash = normalized.lastIndexOf('/');
  return slash <= 0 ? '/' : normalized.substring(0, slash);
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

bool _isChildPath(String path, String parent) {
  final normalizedPath = normalizeGuestPath(path);
  final normalizedParent = normalizeGuestPath(parent);
  if (normalizedParent == '/') {
    return normalizedPath != '/';
  }
  return normalizedPath.startsWith('$normalizedParent/');
}

Map<String, List<Preview1DirectoryEntry>> _buildDirectoryEntriesByPath({
  required Set<String> directories,
  required Map<String, Preview1VirtualFile> filesByGuestPath,
  required Map<String, Preview1VirtualSymlink> symlinksByGuestPath,
}) {
  final childrenByDirectory = <String, Map<String, Preview1DirectoryEntry>>{
    for (final directory in directories)
      directory: <String, Preview1DirectoryEntry>{},
  };

  void addChild({
    required String parent,
    required String name,
    required int fileType,
  }) {
    final children = childrenByDirectory[parent];
    if (children == null || name.isEmpty) {
      return;
    }
    children.putIfAbsent(
      name,
      () => Preview1DirectoryEntry(name: name, fileType: fileType),
    );
  }

  for (final directory in directories) {
    if (directory == '/') {
      continue;
    }
    addChild(
      parent: dirnameOfGuestPath(directory),
      name: basenameOfGuestPath(directory),
      fileType: filetypeDirectory,
    );
  }
  for (final filePath in filesByGuestPath.keys) {
    addChild(
      parent: dirnameOfGuestPath(filePath),
      name: basenameOfGuestPath(filePath),
      fileType: filetypeRegularFile,
    );
  }
  for (final symlinkPath in symlinksByGuestPath.keys) {
    addChild(
      parent: dirnameOfGuestPath(symlinkPath),
      name: basenameOfGuestPath(symlinkPath),
      fileType: filetypeSymbolicLink,
    );
  }

  return {
    for (final entry in childrenByDirectory.entries)
      entry.key: <Preview1DirectoryEntry>[
        Preview1DirectoryEntry(name: '.', fileType: filetypeDirectory),
        Preview1DirectoryEntry(name: '..', fileType: filetypeDirectory),
        ...entry.value.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name)),
      ],
  };
}

void _setUint64(ByteData data, int offset, int value) {
  final normalized = value.toUnsigned(64);
  final low = normalized & 0xffffffff;
  final high = (normalized >> 32) & 0xffffffff;
  data.setUint32(offset, low, Endian.little);
  data.setUint32(offset + 4, high, Endian.little);
}
