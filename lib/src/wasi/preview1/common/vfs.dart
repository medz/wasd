import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../socket.dart';
import 'constants.dart';

typedef _DirectoryChildrenByPath =
    Map<String, Map<String, Preview1DirectoryEntry>>;

final class Preview1VirtualFileSystem {
  Preview1VirtualFileSystem({
    Map<String, String> preopens = const <String, String>{},
    Map<String, Uint8List> files = const <String, Uint8List>{},
    int firstVirtualFd = 64,
    int stdinFd = 0,
    int stdoutFd = 1,
    int stderrFd = 2,
    Map<int, WASIPreview1Socket> sockets = const <int, WASIPreview1Socket>{},
  }) : _nextVirtualFd = firstVirtualFd,
       _stdioDescriptorsByFd = _buildStdioDescriptors(
         stdinFd: stdinFd,
         stdoutFd: stdoutFd,
         stderrFd: stderrFd,
       ),
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
       _preopenDirectoryRightsByFd = {
         for (final indexed in preopens.keys.toList().asMap().entries)
           indexed.key + 3: Preview1DescriptorRights.directory(),
       },
       _filesByGuestPath = {
         for (final entry in files.entries)
           normalizeGuestPath(entry.key): Preview1VirtualFile(entry.value),
       },
       _socketsByFd = {
         for (final entry in sockets.entries)
           entry.key: Preview1VirtualSocket(entry.value),
       },
       _symlinksByGuestPath = <String, Preview1VirtualSymlink>{} {
    _stdioRightsByFd = {
      for (final fd in _stdioDescriptorsByFd.keys)
        fd: Preview1DescriptorRights.file(),
    };
    _stdioFlagsByFd = {for (final fd in _stdioDescriptorsByFd.keys) fd: 0};
    _filePathsByLowerGuestPath = _indexFilePathsByLowerPath(_filesByGuestPath);
    _filePathsByBasenameLower = _indexFilePathsByBasename(
      _filesByGuestPath,
      compact: false,
    );
    _filePathsByBasenameCompact = _indexFilePathsByBasename(
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
    _directoryChildrenByGuestPath = _buildDirectoryChildrenByPath(
      directories: _virtualDirectoryPaths,
      filesByGuestPath: _filesByGuestPath,
      symlinksByGuestPath: _symlinksByGuestPath,
    );
    _directoryEntriesByGuestPath = _buildDirectoryEntriesFromChildren(
      _directoryChildrenByGuestPath,
    );
  }

  final Map<int, Uint8List> _preopenPathBytesByFd;
  final Map<int, String> _preopenGuestPathsByFd;
  final Map<int, int> _preopenDirectoryFlagsByFd;
  final Map<int, Preview1DescriptorRights> _preopenDirectoryRightsByFd;
  final Map<int, Preview1StdioDescriptorKind> _stdioDescriptorsByFd;
  late Map<int, Preview1DescriptorRights> _stdioRightsByFd;
  late Map<int, int> _stdioFlagsByFd;
  final Map<String, Preview1VirtualFile> _filesByGuestPath;
  final Map<int, Preview1VirtualSocket> _socketsByFd;
  final Map<String, Preview1VirtualSymlink> _symlinksByGuestPath;
  final Map<int, Preview1VirtualOpenFile> _openFilesByFd =
      <int, Preview1VirtualOpenFile>{};
  final Map<int, String> _openDirectoriesByFd = <int, String>{};
  final Map<int, int> _openDirectoryFlagsByFd = <int, int>{};
  final Map<int, Preview1DescriptorRights> _openDirectoryRightsByFd =
      <int, Preview1DescriptorRights>{};

  late Map<String, List<String>> _filePathsByLowerGuestPath;
  late Map<String, List<String>> _filePathsByBasenameLower;
  late Map<String, List<String>> _filePathsByBasenameCompact;
  late final Set<String> _virtualDirectoryPaths;
  late Map<String, Preview1VirtualNodeMetadata> _directoryMetadataByGuestPath;
  late _DirectoryChildrenByPath _directoryChildrenByGuestPath;
  late Map<String, List<Preview1DirectoryEntry>> _directoryEntriesByGuestPath;
  int _nextVirtualFd;

  Uint8List? preopenPathBytesForFd(int fd) => _preopenPathBytesByFd[fd];

  String? directoryPathForFd(int fd) =>
      _preopenGuestPathsByFd[fd] ?? _openDirectoriesByFd[fd];

  Preview1VirtualOpenFile? openFileForFd(int fd) => _openFilesByFd[fd];

  Preview1DescriptorKind? descriptorKindForFd(int fd) {
    final stdioKind = _stdioDescriptorsByFd[fd];
    if (stdioKind != null) {
      return switch (stdioKind) {
        Preview1StdioDescriptorKind.stdin => Preview1DescriptorKind.stdin,
        Preview1StdioDescriptorKind.stdout => Preview1DescriptorKind.stdout,
        Preview1StdioDescriptorKind.stderr => Preview1DescriptorKind.stderr,
      };
    }
    if (_openFilesByFd.containsKey(fd)) {
      return Preview1DescriptorKind.file;
    }
    if (_socketsByFd.containsKey(fd)) {
      return Preview1DescriptorKind.socket;
    }
    if (_openDirectoriesByFd.containsKey(fd)) {
      return Preview1DescriptorKind.openDirectory;
    }
    if (_preopenGuestPathsByFd.containsKey(fd)) {
      return Preview1DescriptorKind.preopenDirectory;
    }
    return null;
  }

  Preview1StdioDescriptorKind? stdioKindForFd(int fd) =>
      _stdioDescriptorsByFd[fd];

  Preview1VirtualSocket? socketForFd(int fd) => _socketsByFd[fd];

  Preview1DescriptorRights? descriptorRightsForFd(int fd) {
    final opened = openFileForFd(fd);
    if (opened != null) {
      return opened.rights;
    }
    final socket = socketForFd(fd);
    if (socket != null) {
      return socket.rights;
    }
    return _openDirectoryRightsByFd[fd] ??
        _preopenDirectoryRightsByFd[fd] ??
        _stdioRightsByFd[fd];
  }

  bool descriptorHasRight(int fd, int right) {
    final rights = descriptorRightsForFd(fd);
    return rights != null && (rights.base & right) == right;
  }

  Preview1FdPollReadiness pollFdReadWrite({
    required int fd,
    required int eventType,
    Preview1VirtualOpenFile? stdinInput,
  }) {
    final descriptorKind = descriptorKindForFd(fd);
    if (descriptorKind == null) {
      return const Preview1FdPollReadiness.error(errnoBadf);
    }
    if (!descriptorHasRight(fd, rightPollFdReadwrite)) {
      return const Preview1FdPollReadiness.error(errnoNotcapable);
    }

    return switch (eventType) {
      eventTypeFdRead => _pollFdRead(fd, descriptorKind, stdinInput),
      eventTypeFdWrite => _pollFdWrite(fd, descriptorKind),
      _ => const Preview1FdPollReadiness.error(errnoInval),
    };
  }

  Preview1FdPollReadiness _pollFdRead(
    int fd,
    Preview1DescriptorKind descriptorKind,
    Preview1VirtualOpenFile? stdinInput,
  ) {
    if (!descriptorHasRight(fd, rightFdRead)) {
      return const Preview1FdPollReadiness.error(errnoNotcapable);
    }
    if (descriptorKind == Preview1DescriptorKind.stdin) {
      final nbytes = stdinInput == null
          ? 0
          : math.max(0, stdinInput.length - stdinInput.offset);
      return Preview1FdPollReadiness.ready(
        nbytes: nbytes,
        flags: nbytes == 0 ? eventrwflagFdReadwriteHangup : 0,
      );
    }

    final openFile = openFileForFd(fd);
    if (openFile != null) {
      return Preview1FdPollReadiness.ready(
        nbytes: math.max(0, openFile.length - openFile.offset),
      );
    }

    final socket = socketForFd(fd);
    if (socket != null) {
      if (socket.isDatagram) {
        if (socket.hasReceiveMessage) {
          return Preview1FdPollReadiness.ready(
            nbytes: socket.nextReceiveMessageLength,
          );
        }
      } else {
        if (socket.hasPendingAccept) {
          return const Preview1FdPollReadiness.ready();
        }
        if (socket.remainingReceiveLength > 0) {
          return Preview1FdPollReadiness.ready(
            nbytes: socket.remainingReceiveLength,
          );
        }
      }
      if (socket.receiveShutdown) {
        return const Preview1FdPollReadiness.ready(
          flags: eventrwflagFdReadwriteHangup,
        );
      }
      final readReadyBytes = socket.readReadyBytes;
      if (readReadyBytes != null) {
        return Preview1FdPollReadiness.ready(nbytes: readReadyBytes);
      }
      return const Preview1FdPollReadiness.notReady();
    }

    return const Preview1FdPollReadiness.error(errnoBadf);
  }

  Preview1FdPollReadiness _pollFdWrite(
    int fd,
    Preview1DescriptorKind descriptorKind,
  ) {
    if (!descriptorHasRight(fd, rightFdWrite)) {
      return const Preview1FdPollReadiness.error(errnoNotcapable);
    }
    if (descriptorKind == Preview1DescriptorKind.stdout ||
        descriptorKind == Preview1DescriptorKind.stderr ||
        openFileForFd(fd) != null) {
      return const Preview1FdPollReadiness.ready();
    }

    final socket = socketForFd(fd);
    if (socket != null) {
      if (socket.sendShutdown || socket.writeReady == false) {
        return const Preview1FdPollReadiness.notReady();
      }
      return const Preview1FdPollReadiness.ready();
    }

    return const Preview1FdPollReadiness.error(errnoBadf);
  }

  Preview1FdRightsResult setDescriptorRights({
    required int fd,
    required int rightsBase,
    required int rightsInheriting,
  }) {
    if (fd < 0 ||
        rightsBase < 0 ||
        rightsInheriting < 0 ||
        (rightsBase & ~rightsKnownMask) != 0 ||
        (rightsInheriting & ~rightsKnownMask) != 0) {
      return Preview1FdRightsResult.invalid;
    }
    final rights = descriptorRightsForFd(fd);
    if (rights == null) {
      return Preview1FdRightsResult.badf;
    }
    if ((rightsBase | rights.base) != rights.base ||
        (rightsInheriting | rights.inheriting) != rights.inheriting) {
      return Preview1FdRightsResult.notCapable;
    }
    rights.base = rightsBase;
    rights.inheriting = rightsInheriting;
    return Preview1FdRightsResult.success;
  }

  int? descriptorFlagsForFd(int fd) {
    final opened = openFileForFd(fd);
    if (opened != null) {
      return opened.descriptorFlags;
    }
    final socket = socketForFd(fd);
    if (socket != null) {
      return socket.descriptorFlags;
    }
    return _openDirectoryFlagsByFd[fd] ??
        _preopenDirectoryFlagsByFd[fd] ??
        _stdioFlagsByFd[fd];
  }

  bool setDescriptorFlags(int fd, int flags) {
    final opened = openFileForFd(fd);
    if (opened != null) {
      opened.descriptorFlags = flags;
      return true;
    }
    final socket = socketForFd(fd);
    if (socket != null) {
      socket.descriptorFlags = flags;
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
    if (_stdioDescriptorsByFd.containsKey(fd)) {
      _stdioFlagsByFd[fd] = flags;
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

    final stdioDescriptor = _stdioDescriptorsByFd.remove(fromFd);
    if (stdioDescriptor != null) {
      final rights = _stdioRightsByFd.remove(fromFd);
      final flags = _stdioFlagsByFd.remove(fromFd) ?? 0;
      _closeDescriptor(toFd);
      _stdioDescriptorsByFd[toFd] = stdioDescriptor;
      if (rights != null) {
        _stdioRightsByFd[toFd] = rights;
      }
      _stdioFlagsByFd[toFd] = flags;
      _advanceNextVirtualFdPast(toFd);
      return Preview1FdRenumberResult.success;
    }

    final openFile = _openFilesByFd.remove(fromFd);
    if (openFile != null) {
      _closeDescriptor(toFd);
      _openFilesByFd[toFd] = openFile;
      _advanceNextVirtualFdPast(toFd);
      return Preview1FdRenumberResult.success;
    }

    final socket = _socketsByFd.remove(fromFd);
    if (socket != null) {
      _closeDescriptor(toFd);
      _socketsByFd[toFd] = socket;
      _advanceNextVirtualFdPast(toFd);
      return Preview1FdRenumberResult.success;
    }

    final openDirectory = _openDirectoriesByFd.remove(fromFd);
    if (openDirectory != null) {
      final flags = _openDirectoryFlagsByFd.remove(fromFd) ?? 0;
      final rights =
          _openDirectoryRightsByFd.remove(fromFd) ??
          Preview1DescriptorRights.directory();
      _closeDescriptor(toFd);
      _openDirectoriesByFd[toFd] = openDirectory;
      _openDirectoryFlagsByFd[toFd] = flags;
      _openDirectoryRightsByFd[toFd] = rights;
      _advanceNextVirtualFdPast(toFd);
      return Preview1FdRenumberResult.success;
    }

    final preopenDirectory = _preopenGuestPathsByFd.remove(fromFd);
    if (preopenDirectory != null) {
      final pathBytes = _preopenPathBytesByFd.remove(fromFd);
      final flags = _preopenDirectoryFlagsByFd.remove(fromFd) ?? 0;
      final rights =
          _preopenDirectoryRightsByFd.remove(fromFd) ??
          Preview1DescriptorRights.directory();
      _closeDescriptor(toFd);
      _preopenGuestPathsByFd[toFd] = preopenDirectory;
      if (pathBytes != null) {
        _preopenPathBytesByFd[toFd] = pathBytes;
      }
      _preopenDirectoryFlagsByFd[toFd] = flags;
      _preopenDirectoryRightsByFd[toFd] = rights;
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
    final socket = socketForFd(fd);
    if (socket != null) {
      return socket.metadata;
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
    if (_stdioDescriptorsByFd.remove(fd) != null) {
      _stdioRightsByFd.remove(fd);
      _stdioFlagsByFd.remove(fd);
      return true;
    }
    if (_openFilesByFd.remove(fd) != null) {
      return true;
    }
    if (_socketsByFd.remove(fd) != null) {
      return true;
    }
    if (_openDirectoriesByFd.remove(fd) != null) {
      _openDirectoryFlagsByFd.remove(fd);
      _openDirectoryRightsByFd.remove(fd);
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

    final caseInsensitive = _lookupIndexedFile(
      _filePathsByLowerGuestPath,
      normalized.toLowerCase(),
    );
    if (caseInsensitive != null) {
      return caseInsensitive;
    }

    final basename = basenameOfGuestPath(normalized);
    if (basename.isEmpty) {
      return null;
    }
    final basenameLower = basename.toLowerCase();
    final byBasenameLower = _lookupIndexedFile(
      _filePathsByBasenameLower,
      basenameLower,
    );
    if (byBasenameLower != null) {
      return byBasenameLower;
    }

    final compactBasename = compactPathToken(basenameLower);
    if (compactBasename.isEmpty) {
      return null;
    }
    return _lookupIndexedFile(_filePathsByBasenameCompact, compactBasename);
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
    _directoryChildrenByGuestPath[normalized] =
        <String, Preview1DirectoryEntry>{};
    _setDirectoryChild(normalized, filetypeDirectory);
    _rebuildDirectoryEntriesForPaths({
      dirnameOfGuestPath(normalized),
      normalized,
    });
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

    if (_directoryChildrenByGuestPath[normalized]?.isNotEmpty ?? false) {
      return Preview1PathMutationResult.notEmpty;
    }

    _virtualDirectoryPaths.remove(normalized);
    _directoryMetadataByGuestPath.remove(normalized);
    _removeDirectoryChild(normalized);
    _directoryChildrenByGuestPath.remove(normalized);
    _directoryEntriesByGuestPath.remove(normalized);
    _openDirectoriesByFd.removeWhere((_, path) => path == normalized);
    _openDirectoryFlagsByFd.removeWhere(
      (fd, _) => !_openDirectoriesByFd.containsKey(fd),
    );
    _openDirectoryRightsByFd.removeWhere(
      (fd, _) => !_openDirectoriesByFd.containsKey(fd),
    );
    _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(normalized)});
    return Preview1PathMutationResult.success;
  }

  Preview1PathMutationResult unlinkFile(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    if (_virtualDirectoryPaths.contains(normalized)) {
      return Preview1PathMutationResult.isDirectory;
    }
    if (_symlinksByGuestPath.remove(normalized) != null) {
      _removeDirectoryChild(normalized);
      _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(normalized)});
      return Preview1PathMutationResult.success;
    }
    if (_filesByGuestPath.remove(normalized) == null) {
      return Preview1PathMutationResult.noEntry;
    }

    _unindexFilePath(normalized);
    _removeDirectoryChild(normalized);
    _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(normalized)});
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
      _unindexFilePath(oldNormalized);
      _filesByGuestPath[newNormalized] = oldFile;
      _indexFilePath(newNormalized);
      _removeDirectoryChild(oldNormalized);
      _setDirectoryChild(newNormalized, filetypeRegularFile);
      _rebuildDirectoryEntriesForPaths({
        dirnameOfGuestPath(oldNormalized),
        dirnameOfGuestPath(newNormalized),
      });
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
      _removeDirectoryChild(oldNormalized);
      _setDirectoryChild(newNormalized, filetypeSymbolicLink);
      _rebuildDirectoryEntriesForPaths({
        dirnameOfGuestPath(oldNormalized),
        dirnameOfGuestPath(newNormalized),
      });
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
    _indexFilePath(newNormalized);
    _setDirectoryChild(newNormalized, filetypeRegularFile);
    _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(newNormalized)});
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
    _setDirectoryChild(normalized, filetypeSymbolicLink);
    _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(normalized)});
    return Preview1PathMutationResult.success;
  }

  Preview1VirtualOpenResult openPath(
    String guestPath, {
    int? rightsBase,
    int? rightsInheriting,
    int descriptorFlags = 0,
  }) {
    final normalized = normalizeGuestPath(guestPath);
    final file = lookupFile(normalized);
    if (file != null) {
      final fd = _allocateVirtualFd();
      _openFilesByFd[fd] = Preview1VirtualOpenFile(
        file,
        rights: Preview1DescriptorRights.file(
          base: rightsBase,
          inheriting: rightsInheriting,
        ),
        descriptorFlags: descriptorFlags,
      );
      return Preview1VirtualOpenResult.file(fd);
    }

    if (isDirectoryPath(normalized)) {
      final fd = _allocateVirtualFd();
      _openDirectoriesByFd[fd] = normalized;
      _openDirectoryFlagsByFd[fd] = descriptorFlags;
      _openDirectoryRightsByFd[fd] = Preview1DescriptorRights.directory(
        base: rightsBase,
        inheriting: rightsInheriting,
      );
      return Preview1VirtualOpenResult.directory(fd);
    }

    return const Preview1VirtualOpenResult.missing();
  }

  int acceptSocket({required int fd, required int descriptorFlags}) {
    final listener = socketForFd(fd);
    if (listener == null || !listener.isStream) {
      return -1;
    }
    final accepted = listener.socket.accept();
    if (accepted == null) {
      return -1;
    }
    final acceptedFd = _allocateVirtualFd();
    _socketsByFd[acceptedFd] = Preview1VirtualSocket(
      accepted,
      rights: Preview1DescriptorRights.socket(
        base: listener.rights.inheriting,
        inheriting: 0,
      ),
      descriptorFlags: descriptorFlags,
    );
    return acceptedFd;
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
    _filePathsByLowerGuestPath = _indexFilePathsByLowerPath(_filesByGuestPath);
    _filePathsByBasenameLower = _indexFilePathsByBasename(
      _filesByGuestPath,
      compact: false,
    );
    _filePathsByBasenameCompact = _indexFilePathsByBasename(
      _filesByGuestPath,
      compact: true,
    );
  }

  Preview1VirtualFile? _lookupIndexedFile(
    Map<String, List<String>> index,
    String key,
  ) {
    final paths = index[key];
    if (paths == null || paths.isEmpty) {
      return null;
    }
    return _filesByGuestPath[paths.first];
  }

  void _indexFilePath(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    _addFileIndexPath(
      _filePathsByLowerGuestPath,
      normalized.toLowerCase(),
      normalized,
    );
    final basenameLower = basenameOfGuestPath(normalized).toLowerCase();
    if (basenameLower.isEmpty) {
      return;
    }
    _addFileIndexPath(_filePathsByBasenameLower, basenameLower, normalized);
    final compactBasename = compactPathToken(basenameLower);
    if (compactBasename.isNotEmpty) {
      _addFileIndexPath(
        _filePathsByBasenameCompact,
        compactBasename,
        normalized,
      );
    }
  }

  void _unindexFilePath(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    _removeFileIndexPath(
      _filePathsByLowerGuestPath,
      normalized.toLowerCase(),
      normalized,
    );
    final basenameLower = basenameOfGuestPath(normalized).toLowerCase();
    if (basenameLower.isEmpty) {
      return;
    }
    _removeFileIndexPath(_filePathsByBasenameLower, basenameLower, normalized);
    final compactBasename = compactPathToken(basenameLower);
    if (compactBasename.isEmpty) {
      return;
    }
    _removeFileIndexPath(
      _filePathsByBasenameCompact,
      compactBasename,
      normalized,
    );
  }

  void _addFileIndexPath(
    Map<String, List<String>> index,
    String key,
    String path,
  ) {
    (index[key] ??= <String>[]).add(path);
  }

  void _removeFileIndexPath(
    Map<String, List<String>> index,
    String key,
    String removedPath,
  ) {
    final paths = index[key];
    if (paths == null) {
      return;
    }
    paths.remove(removedPath);
    if (paths.isEmpty) {
      index.remove(key);
    }
  }

  void _rebuildDirectoryEntries() {
    _directoryChildrenByGuestPath = _buildDirectoryChildrenByPath(
      directories: _virtualDirectoryPaths,
      filesByGuestPath: _filesByGuestPath,
      symlinksByGuestPath: _symlinksByGuestPath,
    );
    _directoryEntriesByGuestPath = _buildDirectoryEntriesFromChildren(
      _directoryChildrenByGuestPath,
    );
  }

  void _rebuildDirectoryEntriesForPaths(Set<String> directoryPaths) {
    for (final directoryPath in directoryPaths) {
      final normalized = normalizeGuestPath(directoryPath);
      final children = _directoryChildrenByGuestPath[normalized];
      if (children == null) {
        _directoryEntriesByGuestPath.remove(normalized);
        continue;
      }
      _directoryEntriesByGuestPath[normalized] = _directoryEntryList(children);
    }
  }

  void _setDirectoryChild(String guestPath, int fileType) {
    final normalized = normalizeGuestPath(guestPath);
    final parent = dirnameOfGuestPath(normalized);
    final name = basenameOfGuestPath(normalized);
    final children = _directoryChildrenByGuestPath[parent];
    if (children == null || name.isEmpty) {
      return;
    }
    children[name] = Preview1DirectoryEntry(name: name, fileType: fileType);
  }

  void _removeDirectoryChild(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    final parent = dirnameOfGuestPath(normalized);
    final name = basenameOfGuestPath(normalized);
    if (name.isEmpty) {
      return;
    }
    _directoryChildrenByGuestPath[parent]?.remove(name);
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
      _socketsByFd.containsKey(fd) ||
      _openDirectoriesByFd.containsKey(fd) ||
      _preopenGuestPathsByFd.containsKey(fd) ||
      _stdioDescriptorsByFd.containsKey(fd);

  void _closeDescriptor(int fd) {
    _stdioDescriptorsByFd.remove(fd);
    _stdioRightsByFd.remove(fd);
    _stdioFlagsByFd.remove(fd);
    _openFilesByFd.remove(fd);
    _socketsByFd.remove(fd);
    _openDirectoriesByFd.remove(fd);
    _openDirectoryFlagsByFd.remove(fd);
    _openDirectoryRightsByFd.remove(fd);
    _preopenPathBytesByFd.remove(fd);
    _preopenGuestPathsByFd.remove(fd);
    _preopenDirectoryFlagsByFd.remove(fd);
    _preopenDirectoryRightsByFd.remove(fd);
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

enum Preview1StdioDescriptorKind { stdin, stdout, stderr }

enum Preview1DescriptorKind {
  stdin,
  stdout,
  stderr,
  file,
  socket,
  openDirectory,
  preopenDirectory,
}

final class Preview1DescriptorRights {
  Preview1DescriptorRights({required this.base, required this.inheriting});

  Preview1DescriptorRights.file({int? base, int? inheriting})
    : this(base: base ?? rightsAll, inheriting: inheriting ?? 0);

  Preview1DescriptorRights.directory({int? base, int? inheriting})
    : this(base: base ?? rightsAll, inheriting: inheriting ?? rightsAll);

  Preview1DescriptorRights.socket({int? base, int? inheriting})
    : this(base: base ?? rightsAll, inheriting: inheriting ?? rightsAll);

  int base;
  int inheriting;
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

int readSocketIntoIov({
  required Preview1VirtualSocket socket,
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
  required int flags,
  required int nreadPtr,
  required int roFlagsPtr,
}) {
  if (iovs < 0 ||
      iovsLen < 0 ||
      nreadPtr < 0 ||
      roFlagsPtr < 0 ||
      nreadPtr + 4 > bytes.length ||
      roFlagsPtr + 2 > bytes.length) {
    return errnoInval;
  }

  var totalRead = 0;
  final peek = (flags & riflagRecvPeek) != 0;
  if (socket.isDatagram) {
    return _readDatagramSocketIntoIov(
      socket: socket,
      bytes: bytes,
      data: data,
      iovs: iovs,
      iovsLen: iovsLen,
      peek: peek,
      nreadPtr: nreadPtr,
      roFlagsPtr: roFlagsPtr,
    );
  }
  final waitAll = (flags & riflagRecvWaitall) != 0;
  if (waitAll) {
    final capacity = _socketIovCapacity(
      bytes: bytes,
      data: data,
      iovs: iovs,
      iovsLen: iovsLen,
    );
    if (capacity < 0) {
      return errnoInval;
    }
    if (!socket.receiveShutdown && socket.remainingReceiveLength < capacity) {
      return errnoAgain;
    }
  }
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    if (entry + iovecEntrySize > bytes.length) {
      return errnoInval;
    }

    final buf = data.getUint32(entry, Endian.little);
    final len = data.getUint32(entry + 4, Endian.little);
    if (len > 0 && buf + len > bytes.length) {
      return errnoInval;
    }

    if (len > 0) {
      final read = socket.readInto(
        bytes,
        buf,
        len,
        peek: peek,
        socketOffset: peek ? totalRead : 0,
      );
      totalRead += read;
      if (read < len) {
        break;
      }
    }
  }

  data.setUint32(nreadPtr, totalRead, Endian.little);
  data.setUint16(roFlagsPtr, 0, Endian.little);
  return errnoSuccess;
}

int _readDatagramSocketIntoIov({
  required Preview1VirtualSocket socket,
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
  required bool peek,
  required int nreadPtr,
  required int roFlagsPtr,
}) {
  final capacity = _socketIovCapacity(
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
  );
  if (capacity < 0) {
    return errnoInval;
  }
  if (socket.receiveShutdown || !socket.hasReceiveMessage) {
    data.setUint32(nreadPtr, 0, Endian.little);
    data.setUint16(roFlagsPtr, 0, Endian.little);
    return errnoSuccess;
  }

  var totalRead = 0;
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    final buf = data.getUint32(entry, Endian.little);
    final len = data.getUint32(entry + 4, Endian.little);
    if (len > 0) {
      final read = socket.readMessageInto(
        bytes,
        buf,
        len,
        messageOffset: totalRead,
      );
      totalRead += read;
      if (read < len) {
        break;
      }
    }
  }

  final truncated = totalRead < socket.nextReceiveMessageLength;
  if (!peek) {
    socket.consumeReceiveMessage();
  }
  data.setUint32(nreadPtr, totalRead, Endian.little);
  data.setUint16(
    roFlagsPtr,
    truncated ? roflagRecvDataTruncated : 0,
    Endian.little,
  );
  return errnoSuccess;
}

int _socketIovCapacity({
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
}) {
  var capacity = 0;
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    if (entry + iovecEntrySize > bytes.length) {
      return -1;
    }
    final buf = data.getUint32(entry, Endian.little);
    final len = data.getUint32(entry + 4, Endian.little);
    if (len > 0 && buf + len > bytes.length) {
      return -1;
    }
    capacity += len;
  }
  return capacity;
}

int writeSocketFromIov({
  required Preview1VirtualSocket socket,
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
  required int nwrittenPtr,
}) {
  if (iovs < 0 ||
      iovsLen < 0 ||
      nwrittenPtr < 0 ||
      nwrittenPtr + 4 > bytes.length) {
    return errnoInval;
  }
  if (socket.isDatagram) {
    return _writeDatagramSocketFromIov(
      socket: socket,
      bytes: bytes,
      data: data,
      iovs: iovs,
      iovsLen: iovsLen,
      nwrittenPtr: nwrittenPtr,
    );
  }

  var totalWritten = 0;
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    if (entry + iovecEntrySize > bytes.length) {
      return errnoInval;
    }

    final buf = data.getUint32(entry, Endian.little);
    final len = data.getUint32(entry + 4, Endian.little);
    if (len > 0 && buf + len > bytes.length) {
      return errnoInval;
    }

    if (len > 0) {
      totalWritten += socket.writeFrom(bytes, buf, len);
    }
  }

  data.setUint32(nwrittenPtr, totalWritten, Endian.little);
  return errnoSuccess;
}

int _writeDatagramSocketFromIov({
  required Preview1VirtualSocket socket,
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
  required int nwrittenPtr,
}) {
  final capacity = _socketIovCapacity(
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
  );
  if (capacity < 0) {
    return errnoInval;
  }
  final message = Uint8List(capacity);
  var offset = 0;
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    final buf = data.getUint32(entry, Endian.little);
    final len = data.getUint32(entry + 4, Endian.little);
    if (len > 0) {
      message.setRange(offset, offset + len, bytes, buf);
      offset += len;
    }
  }
  data.setUint32(nwrittenPtr, socket.writeMessage(message), Endian.little);
  return errnoSuccess;
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
  Preview1VirtualOpenFile(
    this.file, {
    Preview1DescriptorRights? rights,
    this.descriptorFlags = 0,
  }) : rights = rights ?? Preview1DescriptorRights.file();

  Preview1VirtualOpenFile.fromBytes(Uint8List bytes)
    : this(Preview1VirtualFile(bytes));

  final Preview1VirtualFile file;
  final Preview1DescriptorRights rights;
  int offset = 0;
  int descriptorFlags;

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

final class Preview1VirtualSocket {
  Preview1VirtualSocket(
    this.socket, {
    Preview1DescriptorRights? rights,
    this.descriptorFlags = 0,
  }) : rights = rights ?? Preview1DescriptorRights.socket();

  final WASIPreview1Socket socket;
  final Preview1DescriptorRights rights;
  final Preview1VirtualNodeMetadata metadata = Preview1VirtualNodeMetadata();
  int descriptorFlags;

  int readInto(
    Uint8List target,
    int start,
    int length, {
    bool peek = false,
    int socketOffset = 0,
  }) => socket.readInto(
    target,
    start,
    length,
    peek: peek,
    socketOffset: socketOffset,
  );

  int writeFrom(Uint8List source, int start, int length) =>
      socket.writeFrom(source, start, length);

  int writeMessage(List<int> data) => socket.writeMessage(data);

  int readMessageInto(
    Uint8List target,
    int start,
    int length, {
    int messageOffset = 0,
  }) => socket.readMessageInto(
    target,
    start,
    length,
    messageOffset: messageOffset,
  );

  void consumeReceiveMessage() {
    socket.consumeReceiveMessage();
  }

  void shutdown({required bool receive, required bool send}) {
    socket.shutdown(receive: receive, send: send);
  }

  bool get sendShutdown => socket.sendShutdown;

  bool get receiveShutdown => socket.receiveShutdown;

  int get remainingReceiveLength => socket.remainingReceiveLength;

  int? get readReadyBytes => socket.readReadyBytes;

  bool? get writeReady => socket.writeReady;

  bool get isDatagram => socket.isDatagram;

  bool get isStream => socket.isStream;

  bool get hasReceiveMessage => socket.hasReceiveMessage;

  bool get hasPendingAccept => socket.hasPendingAccept;

  int get nextReceiveMessageLength => socket.nextReceiveMessageLength;

  int get fileType =>
      socket.isDatagram ? filetypeSocketDgram : filetypeSocketStream;
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

enum Preview1FdRightsResult { success, invalid, badf, notCapable }

final class Preview1FdPollReadiness {
  const Preview1FdPollReadiness._({
    required this.ready,
    required this.errno,
    required this.nbytes,
    required this.flags,
  });

  const Preview1FdPollReadiness.ready({int nbytes = 0, int flags = 0})
    : this._(ready: true, errno: errnoSuccess, nbytes: nbytes, flags: flags);

  const Preview1FdPollReadiness.notReady()
    : this._(ready: false, errno: errnoSuccess, nbytes: 0, flags: 0);

  const Preview1FdPollReadiness.error(int errno)
    : this._(ready: true, errno: errno, nbytes: 0, flags: 0);

  final bool ready;
  final int errno;
  final int nbytes;
  final int flags;
}

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

Map<String, List<String>> _indexFilePathsByLowerPath(
  Map<String, Preview1VirtualFile> filesByGuestPath,
) {
  final indexed = <String, List<String>>{};
  for (final entry in filesByGuestPath.entries) {
    (indexed[entry.key.toLowerCase()] ??= <String>[]).add(entry.key);
  }
  return indexed;
}

Map<String, List<String>> _indexFilePathsByBasename(
  Map<String, Preview1VirtualFile> filesByGuestPath, {
  required bool compact,
}) {
  final indexed = <String, List<String>>{};
  for (final entry in filesByGuestPath.entries) {
    final basenameLower = basenameOfGuestPath(entry.key).toLowerCase();
    if (basenameLower.isEmpty) {
      continue;
    }
    final key = compact ? compactPathToken(basenameLower) : basenameLower;
    if (key.isEmpty) {
      continue;
    }
    (indexed[key] ??= <String>[]).add(entry.key);
  }
  return indexed;
}

Map<int, Preview1StdioDescriptorKind> _buildStdioDescriptors({
  required int stdinFd,
  required int stdoutFd,
  required int stderrFd,
}) {
  return <int, Preview1StdioDescriptorKind>{
    stdinFd: Preview1StdioDescriptorKind.stdin,
    stdoutFd: Preview1StdioDescriptorKind.stdout,
    stderrFd: Preview1StdioDescriptorKind.stderr,
  };
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

_DirectoryChildrenByPath _buildDirectoryChildrenByPath({
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

  return childrenByDirectory;
}

Map<String, List<Preview1DirectoryEntry>> _buildDirectoryEntriesFromChildren(
  _DirectoryChildrenByPath childrenByDirectory,
) {
  return {
    for (final entry in childrenByDirectory.entries)
      entry.key: _directoryEntryList(entry.value),
  };
}

List<Preview1DirectoryEntry> _directoryEntryList(
  Map<String, Preview1DirectoryEntry> children,
) {
  return <Preview1DirectoryEntry>[
    Preview1DirectoryEntry(name: '.', fileType: filetypeDirectory),
    Preview1DirectoryEntry(name: '..', fileType: filetypeDirectory),
    ...children.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
  ];
}

void _setUint64(ByteData data, int offset, int value) {
  final normalized = value.toUnsigned(64);
  final low = normalized & 0xffffffff;
  final high = (normalized >> 32) & 0xffffffff;
  data.setUint32(offset, low, Endian.little);
  data.setUint32(offset + 4, high, Endian.little);
}
