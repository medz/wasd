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
    _validateInitialDescriptorNamespace(
      firstVirtualFd: firstVirtualFd,
      stdinFd: stdinFd,
      stdoutFd: stdoutFd,
      stderrFd: stderrFd,
      preopenFds: _preopenGuestPathsByFd.keys,
      socketFds: sockets.keys,
    );
    _stdioRightsByFd = {
      for (final entry in _stdioDescriptorsByFd.entries)
        entry.key: _stdioRightsFor(entry.value),
    };
    _stdioFlagsByFd = {for (final fd in _stdioDescriptorsByFd.keys) fd: 0};
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
      directoryMetadataByGuestPath: _directoryMetadataByGuestPath,
      filesByGuestPath: _filesByGuestPath,
      symlinksByGuestPath: _symlinksByGuestPath,
    );
    _directoryEntriesByGuestPath = _buildDirectoryEntriesFromChildren(
      _directoryChildrenByGuestPath,
      directoryMetadataByGuestPath: _directoryMetadataByGuestPath,
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
  final Map<int, Preview1OpenFile> _openFilesByFd = <int, Preview1OpenFile>{};
  final Map<int, String> _openDirectoriesByFd = <int, String>{};
  final Map<int, List<Preview1DirectoryEntry>> _openDirectoryEntriesByFd =
      <int, List<Preview1DirectoryEntry>>{};
  final Map<int, Preview1VirtualNodeMetadata> _openDirectoryMetadataByFd =
      <int, Preview1VirtualNodeMetadata>{};
  final Map<int, int> _openDirectoryFlagsByFd = <int, int>{};
  final Map<int, Preview1DescriptorRights> _openDirectoryRightsByFd =
      <int, Preview1DescriptorRights>{};
  final Map<int, String> _openDirectoryHostPathsByFd = <int, String>{};

  late final Set<String> _virtualDirectoryPaths;
  late Map<String, Preview1VirtualNodeMetadata> _directoryMetadataByGuestPath;
  late _DirectoryChildrenByPath _directoryChildrenByGuestPath;
  late Map<String, List<Preview1DirectoryEntry>> _directoryEntriesByGuestPath;
  int _nextVirtualFd;

  Uint8List? preopenPathBytesForFd(int fd) => _preopenPathBytesByFd[fd];

  String? directoryPathForFd(int fd) =>
      _preopenGuestPathsByFd[fd] ?? _openDirectoriesByFd[fd];

  Preview1OpenFile? openFileForFd(int fd) => _openFilesByFd[fd];

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
    Preview1OpenFile? stdinInput,
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
    Preview1OpenFile? stdinInput,
  ) {
    if (descriptorKind == Preview1DescriptorKind.stdin) {
      if (!descriptorHasRight(fd, rightFdRead)) {
        return const Preview1FdPollReadiness.error(errnoNotcapable);
      }
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
      if (!descriptorHasRight(fd, rightFdRead)) {
        return const Preview1FdPollReadiness.error(errnoNotcapable);
      }
      return Preview1FdPollReadiness.ready(
        nbytes: math.max(0, openFile.length - openFile.offset),
      );
    }

    final socket = socketForFd(fd);
    if (socket != null) {
      final hasFdRead = descriptorHasRight(fd, rightFdRead);
      if (socket.receiveShutdown) {
        if (!hasFdRead) {
          return const Preview1FdPollReadiness.error(errnoNotcapable);
        }
        return const Preview1FdPollReadiness.ready(
          flags: eventrwflagFdReadwriteHangup,
        );
      }
      if (socket.isDatagram) {
        if (!hasFdRead) {
          return const Preview1FdPollReadiness.error(errnoNotcapable);
        }
        if (socket.hasReceiveMessage) {
          return Preview1FdPollReadiness.ready(
            nbytes: socket.nextReceiveMessageLength,
          );
        }
        final readReadyBytes = _positiveReadReadyBytes(socket);
        if (readReadyBytes > 0) {
          return Preview1FdPollReadiness.ready(nbytes: readReadyBytes);
        }
      } else {
        final remainingReceiveLength = socket.remainingReceiveLength;
        final readReadyBytes = _positiveReadReadyBytes(socket);
        if (socket.hasPendingAccept) {
          if (descriptorHasRight(fd, rightSockAccept)) {
            return const Preview1FdPollReadiness.ready();
          }
          if (remainingReceiveLength == 0 && readReadyBytes == 0) {
            return const Preview1FdPollReadiness.error(errnoNotcapable);
          }
        }
        if (remainingReceiveLength > 0) {
          if (!hasFdRead) {
            return const Preview1FdPollReadiness.error(errnoNotcapable);
          }
          return Preview1FdPollReadiness.ready(nbytes: remainingReceiveLength);
        }
        if (readReadyBytes > 0) {
          if (!hasFdRead) {
            return const Preview1FdPollReadiness.error(errnoNotcapable);
          }
          return Preview1FdPollReadiness.ready(nbytes: readReadyBytes);
        }
        if (hasFdRead) {
          socket.ensureReceiveData(1);
          final pulledReceiveLength = socket.remainingReceiveLength;
          if (pulledReceiveLength > 0) {
            return Preview1FdPollReadiness.ready(nbytes: pulledReceiveLength);
          }
        }
      }
      if (!hasFdRead) {
        return const Preview1FdPollReadiness.error(errnoNotcapable);
      }
      return const Preview1FdPollReadiness.notReady();
    }

    return const Preview1FdPollReadiness.error(errnoBadf);
  }

  int _positiveReadReadyBytes(Preview1VirtualSocket socket) {
    final readReadyBytes = socket.readReadyBytes;
    return readReadyBytes != null && readReadyBytes > 0 ? readReadyBytes : 0;
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
      if (socket.sendShutdown) {
        return const Preview1FdPollReadiness.ready(
          flags: eventrwflagFdReadwriteHangup,
        );
      }
      if (socket.writeReady == false) {
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
    if (!_hasDescriptor(toFd)) {
      return Preview1FdRenumberResult.badf;
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
      final entries = _openDirectoryEntriesByFd.remove(fromFd);
      final metadata = _openDirectoryMetadataByFd.remove(fromFd);
      final hostPath = _openDirectoryHostPathsByFd.remove(fromFd);
      final rights =
          _openDirectoryRightsByFd.remove(fromFd) ??
          Preview1DescriptorRights.directory();
      _closeDescriptor(toFd);
      _openDirectoriesByFd[toFd] = openDirectory;
      if (entries != null) {
        _openDirectoryEntriesByFd[toFd] = entries;
      }
      if (metadata != null) {
        _openDirectoryMetadataByFd[toFd] = metadata;
      }
      if (hostPath != null) {
        _openDirectoryHostPathsByFd[toFd] = hostPath;
      }
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

  String? openDirectoryHostPathForFd(int fd) => _openDirectoryHostPathsByFd[fd];

  bool isDirectoryFd(int fd) =>
      isPreopenDirectoryFd(fd) || isOpenDirectoryFd(fd);

  List<Preview1DirectoryEntry>? directoryEntriesForFd(int fd) {
    final openedEntries = _openDirectoryEntriesByFd[fd];
    if (openedEntries != null) {
      return openedEntries;
    }
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
    final openDirectoryMetadata = _openDirectoryMetadataByFd[fd];
    if (openDirectoryMetadata != null) {
      return openDirectoryMetadata;
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
      final resolved = _resolveFirstSymlinkComponent(current);
      if (resolved == null) {
        return current;
      }
      current = resolved;
    }
    return null;
  }

  String? resolveParentSymlinkPath(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    if (normalized == '/') {
      return normalized;
    }
    final parent = resolveSymlinkPath(dirnameOfGuestPath(normalized));
    if (parent == null) {
      return null;
    }
    return joinGuestPath(parent, basenameOfGuestPath(normalized));
  }

  String? _resolveFirstSymlinkComponent(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    if (normalized == '/') {
      return null;
    }

    final segments = normalized.substring(1).split('/');
    var prefix = '';
    for (var i = 0; i < segments.length; i++) {
      prefix = prefix.isEmpty ? '/${segments[i]}' : '$prefix/${segments[i]}';
      final symlink = _symlinksByGuestPath[prefix];
      if (symlink == null) {
        continue;
      }
      final targetPath = symlink.target.startsWith('/')
          ? normalizeGuestPath(symlink.target)
          : joinGuestPath(dirnameOfGuestPath(prefix), symlink.target);
      final remaining = segments.skip(i + 1).join('/');
      return remaining.isEmpty
          ? targetPath
          : joinGuestPath(targetPath, remaining);
    }
    return null;
  }

  bool close(int fd) {
    if (!_hasDescriptor(fd)) {
      return false;
    }
    _closeDescriptor(fd);
    return true;
  }

  Preview1VirtualFile? lookupFile(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    return _filesByGuestPath[normalized];
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

    final removedMetadata = _directoryMetadataByGuestPath[normalized];
    final removedEntries = _directoryEntriesByGuestPath[normalized];
    if (removedMetadata != null && removedEntries != null) {
      removedMetadata.releaseLink();
      final snapshotEntries = List<Preview1DirectoryEntry>.unmodifiable(
        removedEntries,
      );
      for (final entry in _openDirectoriesByFd.entries) {
        if (entry.value == normalized) {
          _openDirectoryEntriesByFd[entry.key] = snapshotEntries;
          _openDirectoryMetadataByFd[entry.key] = removedMetadata;
        }
      }
    }

    _virtualDirectoryPaths.remove(normalized);
    _directoryMetadataByGuestPath.remove(normalized);
    _removeDirectoryChild(normalized);
    _directoryChildrenByGuestPath.remove(normalized);
    _directoryEntriesByGuestPath.remove(normalized);
    _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(normalized)});
    return Preview1PathMutationResult.success;
  }

  Preview1PathMutationResult unlinkFile(
    String guestPath, {
    bool hasTrailingSeparator = false,
  }) {
    final normalized = normalizeGuestPath(guestPath);
    if (hasTrailingSeparator) {
      if (_virtualDirectoryPaths.contains(normalized)) {
        return Preview1PathMutationResult.isDirectory;
      }
      if (_filesByGuestPath.containsKey(normalized) ||
          _symlinksByGuestPath.containsKey(normalized)) {
        return Preview1PathMutationResult.notDirectory;
      }
      return Preview1PathMutationResult.noEntry;
    }
    if (_virtualDirectoryPaths.contains(normalized)) {
      return Preview1PathMutationResult.isDirectory;
    }
    final removedSymlink = _symlinksByGuestPath.remove(normalized);
    if (removedSymlink != null) {
      removedSymlink.metadata.releaseLink();
      _removeDirectoryChild(normalized);
      _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(normalized)});
      return Preview1PathMutationResult.success;
    }
    final removedFile = _filesByGuestPath.remove(normalized);
    if (removedFile == null) {
      return Preview1PathMutationResult.noEntry;
    }

    removedFile.metadata.releaseLink();
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
      if (oldNormalized == newNormalized) {
        return Preview1PathMutationResult.success;
      }
      if (_virtualDirectoryPaths.contains(newNormalized)) {
        return Preview1PathMutationResult.isDirectory;
      }
      final replacedFile = _filesByGuestPath[newNormalized];
      if (identical(replacedFile, oldFile)) {
        _filesByGuestPath.remove(oldNormalized);
        oldFile.metadata.releaseLink();
        _removeDirectoryChild(oldNormalized);
        _setDirectoryChild(newNormalized, filetypeRegularFile);
        _rebuildDirectoryEntriesForPaths({
          dirnameOfGuestPath(oldNormalized),
          dirnameOfGuestPath(newNormalized),
        });
        return Preview1PathMutationResult.success;
      }
      if (replacedFile != null) {
        _filesByGuestPath.remove(newNormalized);
        replacedFile.metadata.releaseLink();
      }
      final replacedSymlink = _symlinksByGuestPath.remove(newNormalized);
      if (replacedSymlink != null) {
        replacedSymlink.metadata.releaseLink();
      }
      _filesByGuestPath.remove(oldNormalized);
      _filesByGuestPath[newNormalized] = oldFile;
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
      if (oldNormalized == newNormalized) {
        return Preview1PathMutationResult.success;
      }
      if (_virtualDirectoryPaths.contains(newNormalized)) {
        return Preview1PathMutationResult.isDirectory;
      }
      final replacedSymlink = _symlinksByGuestPath[newNormalized];
      if (identical(replacedSymlink, oldSymlink)) {
        _symlinksByGuestPath.remove(oldNormalized);
        oldSymlink.metadata.releaseLink();
        _removeDirectoryChild(oldNormalized);
        _setDirectoryChild(newNormalized, filetypeSymbolicLink);
        _rebuildDirectoryEntriesForPaths({
          dirnameOfGuestPath(oldNormalized),
          dirnameOfGuestPath(newNormalized),
        });
        return Preview1PathMutationResult.success;
      }
      final replacedFile = _filesByGuestPath.remove(newNormalized);
      if (replacedFile != null) {
        replacedFile.metadata.releaseLink();
      }
      if (replacedSymlink != null) {
        _symlinksByGuestPath.remove(newNormalized);
        replacedSymlink.metadata.releaseLink();
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
      if (_directoryChildrenByGuestPath[newNormalized]?.isNotEmpty ?? false) {
        return Preview1PathMutationResult.notEmpty;
      }
    }

    _renameDirectory(oldNormalized, newNormalized);
    return Preview1PathMutationResult.success;
  }

  Preview1PathMutationResult linkPath({
    required String oldPath,
    required String newPath,
    bool oldPathFollowSymlinks = false,
    bool newPathHasTrailingSeparator = false,
  }) {
    final oldNormalized = oldPathFollowSymlinks
        ? resolveSymlinkPath(oldPath)
        : normalizeGuestPath(oldPath);
    if (oldNormalized == null) {
      return Preview1PathMutationResult.symlinkLoop;
    }
    final newNormalized = normalizeGuestPath(newPath);
    if (newPathHasTrailingSeparator) {
      if (_virtualDirectoryPaths.contains(newNormalized)) {
        return Preview1PathMutationResult.exists;
      }
      if (_filesByGuestPath.containsKey(newNormalized) ||
          _symlinksByGuestPath.containsKey(newNormalized)) {
        return Preview1PathMutationResult.notDirectory;
      }
      return Preview1PathMutationResult.noEntry;
    }
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
    if (oldFile != null) {
      _filesByGuestPath[newNormalized] = oldFile;
      oldFile.metadata.retainLink();
      _setDirectoryChild(newNormalized, filetypeRegularFile);
      _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(newNormalized)});
      return Preview1PathMutationResult.success;
    }

    final oldSymlink = _symlinksByGuestPath[oldNormalized];
    if (oldSymlink != null) {
      _symlinksByGuestPath[newNormalized] = oldSymlink;
      oldSymlink.metadata.retainLink();
      _setDirectoryChild(newNormalized, filetypeSymbolicLink);
      _rebuildDirectoryEntriesForPaths({dirnameOfGuestPath(newNormalized)});
      return Preview1PathMutationResult.success;
    }

    if (_virtualDirectoryPaths.contains(oldNormalized)) {
      return Preview1PathMutationResult.permissionDenied;
    }
    return Preview1PathMutationResult.noEntry;
  }

  Preview1PathMutationResult createSymlink({
    required String target,
    required String linkPath,
    bool hasTrailingSeparator = false,
  }) {
    if (isAbsoluteGuestPath(target)) {
      return Preview1PathMutationResult.notCapable;
    }
    final normalized = normalizeGuestPath(linkPath);
    if (hasTrailingSeparator) {
      if (_virtualDirectoryPaths.contains(normalized)) {
        return Preview1PathMutationResult.exists;
      }
      if (_filesByGuestPath.containsKey(normalized) ||
          _symlinksByGuestPath.containsKey(normalized)) {
        return Preview1PathMutationResult.notDirectory;
      }
      return Preview1PathMutationResult.noEntry;
    }
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
    int oflags = 0,
    bool hasTrailingSeparator = false,
  }) {
    final normalized = normalizeGuestPath(guestPath);
    final create = (oflags & oflagCreat) != 0;
    final directory = (oflags & oflagDirectory) != 0;
    final exclusive = (oflags & oflagExcl) != 0;
    final truncate = (oflags & oflagTrunc) != 0;
    final file = lookupFile(normalized);
    if (file != null) {
      if (hasTrailingSeparator) {
        return const Preview1VirtualOpenResult.notDirectory();
      }
      if (directory) {
        return const Preview1VirtualOpenResult.notDirectory();
      }
      if (create && exclusive) {
        return const Preview1VirtualOpenResult.exists();
      }
      if (truncate) {
        file.setLength(0);
      }
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

    if (_symlinksByGuestPath.containsKey(normalized)) {
      if (create && exclusive) {
        return const Preview1VirtualOpenResult.exists();
      }
      return const Preview1VirtualOpenResult.symlinkLoop();
    }

    if (isDirectoryPath(normalized)) {
      if (create && exclusive) {
        return const Preview1VirtualOpenResult.exists();
      }
      if (truncate) {
        return const Preview1VirtualOpenResult.isDirectory();
      }
      final requestsOnlyFileReadWriteRights =
          rightsBase != null &&
          (rightsBase & rightFdWrite) != 0 &&
          (rightsBase & ~(rightFdRead | rightFdWrite)) == 0;
      if (directory && requestsOnlyFileReadWriteRights) {
        return const Preview1VirtualOpenResult.isDirectory();
      }
      final fd = _allocateVirtualFd();
      _openDirectoriesByFd[fd] = normalized;
      _openDirectoryFlagsByFd[fd] = descriptorFlags;
      _openDirectoryRightsByFd[fd] = Preview1DescriptorRights.directory(
        base: rightsBase,
        inheriting: rightsInheriting,
      );
      return Preview1VirtualOpenResult.directory(fd);
    }

    if (directory || !create) {
      return const Preview1VirtualOpenResult.missing();
    }

    final parent = dirnameOfGuestPath(normalized);
    if (_filesByGuestPath.containsKey(parent) ||
        _symlinksByGuestPath.containsKey(parent)) {
      return const Preview1VirtualOpenResult.notDirectory();
    }
    if (!_virtualDirectoryPaths.contains(parent)) {
      return const Preview1VirtualOpenResult.missing();
    }

    final created = Preview1VirtualFile(Uint8List(0));
    _filesByGuestPath[normalized] = created;
    _setDirectoryChild(normalized, filetypeRegularFile);
    _rebuildDirectoryEntriesForPaths({parent});
    final fd = _allocateVirtualFd();
    _openFilesByFd[fd] = Preview1VirtualOpenFile(
      created,
      rights: Preview1DescriptorRights.file(
        base: rightsBase,
        inheriting: rightsInheriting,
      ),
      descriptorFlags: descriptorFlags,
    );
    return Preview1VirtualOpenResult.file(fd);
  }

  Preview1VirtualOpenResult openFileHandle(Preview1OpenFile opened) {
    final fd = _allocateVirtualFd();
    _openFilesByFd[fd] = opened;
    return Preview1VirtualOpenResult.file(fd);
  }

  Preview1VirtualOpenResult openDirectoryHandle(
    String guestPath, {
    required List<Preview1DirectoryEntry> entries,
    required Preview1VirtualNodeMetadata metadata,
    String? hostPath,
    int? rightsBase,
    int? rightsInheriting,
    int descriptorFlags = 0,
  }) {
    final fd = _allocateVirtualFd();
    _openDirectoriesByFd[fd] = normalizeGuestPath(guestPath);
    _openDirectoryEntriesByFd[fd] = List<Preview1DirectoryEntry>.unmodifiable(
      entries,
    );
    _openDirectoryMetadataByFd[fd] = metadata;
    if (hostPath != null) {
      _openDirectoryHostPathsByFd[fd] = hostPath;
    }
    _openDirectoryFlagsByFd[fd] = descriptorFlags;
    _openDirectoryRightsByFd[fd] = Preview1DescriptorRights.directory(
      base: rightsBase,
      inheriting: rightsInheriting,
    );
    return Preview1VirtualOpenResult.directory(fd);
  }

  int acceptSocket({required int fd, required int descriptorFlags}) {
    final listener = socketForFd(fd);
    if (listener == null || !listener.isStream || !listener.canAccept) {
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
        base: listener.rights.inheriting & ~rightSockAccept,
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
    _rebuildDirectoryEntries();
  }

  void _rebuildDirectoryEntries() {
    _directoryChildrenByGuestPath = _buildDirectoryChildrenByPath(
      directories: _virtualDirectoryPaths,
      directoryMetadataByGuestPath: _directoryMetadataByGuestPath,
      filesByGuestPath: _filesByGuestPath,
      symlinksByGuestPath: _symlinksByGuestPath,
    );
    _directoryEntriesByGuestPath = _buildDirectoryEntriesFromChildren(
      _directoryChildrenByGuestPath,
      directoryMetadataByGuestPath: _directoryMetadataByGuestPath,
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
      _directoryEntriesByGuestPath[normalized] = _directoryEntryList(
        directoryPath: normalized,
        children: children,
        directoryMetadataByGuestPath: _directoryMetadataByGuestPath,
      );
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
    children[name] = Preview1DirectoryEntry(
      name: name,
      fileType: fileType,
      inode: _inodeForPath(normalized),
    );
  }

  int _inodeForPath(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    final file = _filesByGuestPath[normalized];
    if (file != null) {
      return file.metadata.inode;
    }
    final symlink = _symlinksByGuestPath[normalized];
    if (symlink != null) {
      return symlink.metadata.inode;
    }
    return _directoryMetadataByGuestPath[normalized]?.inode ?? 0;
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
    _openFilesByFd.remove(fd)?.close();
    _socketsByFd.remove(fd);
    _openDirectoriesByFd.remove(fd);
    _openDirectoryEntriesByFd.remove(fd);
    _openDirectoryMetadataByFd.remove(fd);
    _openDirectoryHostPathsByFd.remove(fd);
    _openDirectoryFlagsByFd.remove(fd);
    _openDirectoryRightsByFd.remove(fd);
    _preopenPathBytesByFd.remove(fd);
    _preopenGuestPathsByFd.remove(fd);
    _preopenDirectoryFlagsByFd.remove(fd);
    _preopenDirectoryRightsByFd.remove(fd);
  }
}

final class Preview1DirectoryEntry {
  Preview1DirectoryEntry({
    required this.name,
    required this.fileType,
    required this.inode,
  }) : nameBytes = pathBytes(name);

  final String name;
  final Uint8List nameBytes;
  final int fileType;
  final int inode;
}

final class Preview1VirtualNodeMetadata {
  factory Preview1VirtualNodeMetadata({int? inode, int? timestampNanos}) {
    return Preview1VirtualNodeMetadata._(
      inode ?? _nextInode++,
      timestampNanos ?? _allocateTimestampNanos(),
    );
  }

  Preview1VirtualNodeMetadata._(this.inode, int timestampNanos)
    : accessTimeNanos = timestampNanos,
      modificationTimeNanos = timestampNanos;

  static int _nextInode = 1;
  static int _nextTimestampNanos = _initialTimestampNanos();

  final int device = 1;
  final int inode;
  int linkCount = 1;
  int accessTimeNanos;
  int modificationTimeNanos;

  static int _initialTimestampNanos() {
    final nanos = DateTime.now().microsecondsSinceEpoch * 1000;
    return nanos <= 0 ? 1 : nanos;
  }

  static int _allocateTimestampNanos() {
    final timestamp = _nextTimestampNanos;
    _nextTimestampNanos = timestamp + 1;
    return timestamp;
  }

  void retainLink() {
    linkCount++;
  }

  void releaseLink() {
    if (linkCount > 0) {
      linkCount--;
    }
  }
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
    : this(
        base: (base ?? rightsDirectoryBase) & rightsDirectoryBase,
        inheriting: inheriting ?? rightsAll,
      );

  Preview1DescriptorRights.socket({
    int? base,
    int? inheriting,
    bool canAccept = true,
  }) : this(
         base: base ?? (canAccept ? rightsSocket : rightsSocketInheriting),
         inheriting: inheriting ?? (canAccept ? rightsSocketInheriting : 0),
       );

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
      return bufferLength;
    }

    final entry = entries[index];
    final entryPtr = bufferPtr + written;
    bytes.fillRange(entryPtr, entryPtr + direntSize, 0);
    _setUint64(data, entryPtr + direntNextOffset, index + 1);
    _setUint64(data, entryPtr + direntInodeOffset, entry.inode);
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

void writeFilestatMetadata({
  required ByteData data,
  required int filestatPtr,
  required Preview1VirtualNodeMetadata metadata,
}) {
  _setUint64(data, filestatPtr + filestatDeviceOffset, metadata.device);
  _setUint64(data, filestatPtr + filestatInodeOffset, metadata.inode);
  _setUint64(data, filestatPtr + filestatLinkCountOffset, metadata.linkCount);
  _setUint64(
    data,
    filestatPtr + filestatAccessTimeOffset,
    metadata.accessTimeNanos,
  );
  _setUint64(
    data,
    filestatPtr + filestatModificationTimeOffset,
    metadata.modificationTimeNanos,
  );
}

int readSocketIntoIov({
  required Preview1VirtualSocket socket,
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
  required int flags,
  required int nreadPtr,
  required int? roFlagsPtr,
}) {
  if (iovs < 0 ||
      iovsLen < 0 ||
      nreadPtr < 0 ||
      nreadPtr + 4 > bytes.length ||
      (roFlagsPtr != null &&
          (roFlagsPtr < 0 || roFlagsPtr + 2 > bytes.length))) {
    return errnoInval;
  }

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
  final iovState = _iovState(
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
  );
  if (iovState == _iovInvalid) {
    return errnoInval;
  }
  final capacity = _iovCapacityFromState(iovState);
  final iovSnapshot = _iovNeedsSnapshot(iovState)
      ? _snapshotIovs(data: data, iovs: iovs, iovsLen: iovsLen)
      : null;
  var totalRead = 0;
  final waitAll = (flags & riflagRecvWaitall) != 0;
  if (waitAll) {
    if (!socket.receiveShutdown && socket.remainingReceiveLength < capacity) {
      socket.ensureReceiveData(capacity, drainUntilSatisfied: true);
    }
    if (!socket.receiveShutdown && socket.remainingReceiveLength < capacity) {
      return errnoAgain;
    }
  }
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    final snapshotIndex = index * 2;
    final buf = iovSnapshot == null
        ? data.getUint32(entry, Endian.little)
        : iovSnapshot[snapshotIndex];
    final len = iovSnapshot == null
        ? data.getUint32(entry + 4, Endian.little)
        : iovSnapshot[snapshotIndex + 1];

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

  if (totalRead == 0 && capacity > 0 && !socket.receiveShutdown) {
    return errnoAgain;
  }
  _writeSocketReadResult(data, nreadPtr, roFlagsPtr, totalRead, 0);
  return errnoSuccess;
}

void _writeSocketReadResult(
  ByteData data,
  int nreadPtr,
  int? roFlagsPtr,
  int nread,
  int roFlags,
) {
  data.setUint32(nreadPtr, nread, Endian.little);
  if (roFlagsPtr != null) {
    data.setUint16(roFlagsPtr, roFlags, Endian.little);
  }
}

int _readDatagramSocketIntoIov({
  required Preview1VirtualSocket socket,
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
  required bool peek,
  required int nreadPtr,
  required int? roFlagsPtr,
}) {
  final iovState = _iovState(
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
  );
  if (iovState == _iovInvalid) {
    return errnoInval;
  }
  final capacity = _iovCapacityFromState(iovState);
  final iovSnapshot = _iovNeedsSnapshot(iovState)
      ? _snapshotIovs(data: data, iovs: iovs, iovsLen: iovsLen)
      : null;
  if (!socket.receiveShutdown && !socket.hasReceiveMessage) {
    if (capacity > 0) {
      return errnoAgain;
    }
    _writeSocketReadResult(data, nreadPtr, roFlagsPtr, 0, 0);
    return errnoSuccess;
  }
  if (socket.receiveShutdown) {
    _writeSocketReadResult(data, nreadPtr, roFlagsPtr, 0, 0);
    return errnoSuccess;
  }

  var totalRead = 0;
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    final snapshotIndex = index * 2;
    final buf = iovSnapshot == null
        ? data.getUint32(entry, Endian.little)
        : iovSnapshot[snapshotIndex];
    final len = iovSnapshot == null
        ? data.getUint32(entry + 4, Endian.little)
        : iovSnapshot[snapshotIndex + 1];
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
  _writeSocketReadResult(
    data,
    nreadPtr,
    roFlagsPtr,
    totalRead,
    truncated ? roflagRecvDataTruncated : 0,
  );
  return errnoSuccess;
}

const int _iovInvalid = -1;

// Non-negative values are capacities. Values below [_iovInvalid] encode a
// capacity whose buffers overlap the iovec table and require a snapshot before
// host writes can mutate those descriptors.
int _iovState({
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
}) {
  var capacity = 0;
  var overlapsIovTable = false;
  final iovTableEnd = iovs + iovsLen * iovecEntrySize;
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    if (entry + iovecEntrySize > bytes.length) {
      return _iovInvalid;
    }
    final buf = data.getUint32(entry, Endian.little);
    final len = data.getUint32(entry + 4, Endian.little);
    if (len > 0 && buf + len > bytes.length) {
      return _iovInvalid;
    }
    if (len > 0 && _rangesOverlap(buf, buf + len, iovs, iovTableEnd)) {
      overlapsIovTable = true;
    }
    capacity += len;
  }
  return overlapsIovTable ? -capacity - 2 : capacity;
}

bool _iovNeedsSnapshot(int state) => state < _iovInvalid;

int _iovCapacityFromState(int state) =>
    _iovNeedsSnapshot(state) ? -state - 2 : state;

List<int> _snapshotIovs({
  required ByteData data,
  required int iovs,
  required int iovsLen,
}) {
  final snapshot = List<int>.filled(iovsLen * 2, 0);
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    final snapshotIndex = index * 2;
    snapshot[snapshotIndex] = data.getUint32(entry, Endian.little);
    snapshot[snapshotIndex + 1] = data.getUint32(entry + 4, Endian.little);
  }
  return snapshot;
}

bool _rangesOverlap(int start, int end, int otherStart, int otherEnd) =>
    start < otherEnd && otherStart < end;

int readOpenFileIntoIov({
  required Preview1OpenFile opened,
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
  required int nreadPtr,
  int? fileOffset,
}) {
  if (iovs < 0 ||
      iovsLen < 0 ||
      nreadPtr < 0 ||
      nreadPtr + 4 > bytes.length ||
      (fileOffset != null && fileOffset < 0)) {
    return errnoInval;
  }
  final iovState = _iovState(
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
  );
  if (iovState == _iovInvalid) {
    return errnoInval;
  }
  final iovSnapshot = _iovNeedsSnapshot(iovState)
      ? _snapshotIovs(data: data, iovs: iovs, iovsLen: iovsLen)
      : null;

  var totalRead = 0;
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    final snapshotIndex = index * 2;
    final buf = iovSnapshot == null
        ? data.getUint32(entry, Endian.little)
        : iovSnapshot[snapshotIndex];
    final len = iovSnapshot == null
        ? data.getUint32(entry + 4, Endian.little)
        : iovSnapshot[snapshotIndex + 1];

    if (len > 0) {
      totalRead += fileOffset == null
          ? opened.readInto(bytes, buf, len)
          : opened.readAtInto(bytes, buf, len, fileOffset + totalRead);
    }
  }

  if (totalRead > 0) {
    _syncOpenFileAfterRead(opened);
  }
  data.setUint32(nreadPtr, totalRead, Endian.little);
  return errnoSuccess;
}

int writeOpenFileFromIov({
  required Preview1OpenFile opened,
  required Uint8List bytes,
  required ByteData data,
  required int iovs,
  required int iovsLen,
  required int nwrittenPtr,
  int? fileOffset,
}) {
  if (iovs < 0 ||
      iovsLen < 0 ||
      nwrittenPtr < 0 ||
      nwrittenPtr + 4 > bytes.length ||
      (fileOffset != null && fileOffset < 0)) {
    return errnoInval;
  }
  final iovState = _iovState(
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
  );
  if (iovState == _iovInvalid) {
    return errnoInval;
  }

  var totalWritten = 0;
  final append = (opened.descriptorFlags & fdflagAppend) != 0;
  for (var index = 0; index < iovsLen; index++) {
    final entry = iovs + index * iovecEntrySize;
    final buf = data.getUint32(entry, Endian.little);
    final len = data.getUint32(entry + 4, Endian.little);

    if (len > 0) {
      totalWritten += fileOffset == null
          ? opened.writeFrom(bytes, buf, len)
          : opened.writeAtFrom(
              bytes,
              buf,
              len,
              append ? opened.length : fileOffset + totalWritten,
            );
    }
  }

  if (totalWritten > 0) {
    _syncOpenFileAfterWrite(opened);
  }
  data.setUint32(nwrittenPtr, totalWritten, Endian.little);
  return errnoSuccess;
}

void _syncOpenFileAfterWrite(Preview1OpenFile opened) {
  final flags = opened.descriptorFlags;
  if ((flags & fdflagSync) != 0) {
    opened.sync();
  } else if ((flags & fdflagDsync) != 0) {
    opened.dataSync();
  }
}

void _syncOpenFileAfterRead(Preview1OpenFile opened) {
  final flags = opened.descriptorFlags;
  if ((flags & fdflagRsync) == 0) {
    return;
  }
  if ((flags & fdflagDsync) != 0 && (flags & fdflagSync) == 0) {
    opened.dataSync();
  } else {
    opened.sync();
  }
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
  final iovState = _iovState(
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
  );
  if (iovState == _iovInvalid) {
    return errnoInval;
  }
  final capacity = _iovCapacityFromState(iovState);
  if (socket.sendShutdown) {
    return errnoPipe;
  }
  if (socket.isStream && capacity == 0) {
    data.setUint32(nwrittenPtr, 0, Endian.little);
    return errnoSuccess;
  }
  if (socket.writeReady == false) {
    return errnoAgain;
  }
  if (socket.isDatagram) {
    return _writeDatagramSocketFromIov(
      socket: socket,
      bytes: bytes,
      data: data,
      iovs: iovs,
      iovsLen: iovsLen,
      capacity: capacity,
      nwrittenPtr: nwrittenPtr,
    );
  }

  final iovSnapshot = _iovNeedsSnapshot(iovState)
      ? _snapshotIovs(data: data, iovs: iovs, iovsLen: iovsLen)
      : null;
  var totalWritten = 0;
  try {
    for (var index = 0; index < iovsLen; index++) {
      final entry = iovs + index * iovecEntrySize;
      if (entry + iovecEntrySize > bytes.length) {
        return errnoInval;
      }

      final snapshotIndex = index * 2;
      final buf = iovSnapshot == null
          ? data.getUint32(entry, Endian.little)
          : iovSnapshot[snapshotIndex];
      final len = iovSnapshot == null
          ? data.getUint32(entry + 4, Endian.little)
          : iovSnapshot[snapshotIndex + 1];

      if (len > 0) {
        final written = socket.writeFrom(bytes, buf, len);
        totalWritten += written;
        if (written < len) {
          break;
        }
      }
    }
  } on RangeError {
    return errnoInval;
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
  required int capacity,
  required int nwrittenPtr,
}) {
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
  int written;
  try {
    written = socket.writeOwnedMessage(message);
  } on RangeError {
    return errnoInval;
  }
  data.setUint32(nwrittenPtr, written, Endian.little);
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

abstract interface class Preview1OpenFile {
  Preview1DescriptorRights get rights;

  int get offset;
  set offset(int value);

  int get descriptorFlags;
  set descriptorFlags(int value);

  int get length;

  Preview1VirtualNodeMetadata get metadata;

  int readInto(Uint8List target, int start, int length);

  int readAtInto(Uint8List target, int start, int length, int fileOffset);

  int writeFrom(Uint8List source, int start, int length);

  int writeAtFrom(Uint8List source, int start, int length, int fileOffset);

  void setLength(int length);

  void allocate(int offset, int length);

  void dataSync();

  void sync();

  void close();
}

final class Preview1VirtualOpenFile implements Preview1OpenFile {
  Preview1VirtualOpenFile(
    this.file, {
    Preview1DescriptorRights? rights,
    this.descriptorFlags = 0,
  }) : rights = rights ?? Preview1DescriptorRights.file();

  Preview1VirtualOpenFile.fromBytes(Uint8List bytes)
    : this(Preview1VirtualFile(bytes));

  final Preview1VirtualFile file;
  @override
  final Preview1DescriptorRights rights;
  @override
  int offset = 0;
  @override
  int descriptorFlags;

  Uint8List get bytes => file.bytes;

  @override
  int get length => file.length;

  @override
  Preview1VirtualNodeMetadata get metadata => file.metadata;

  @override
  int readInto(Uint8List target, int start, int length) {
    final count = readAtInto(target, start, length, offset);
    offset += count;
    return count;
  }

  @override
  int readAtInto(Uint8List target, int start, int length, int fileOffset) =>
      file.readAtInto(target, start, length, fileOffset);

  @override
  int writeFrom(Uint8List source, int start, int length) {
    final fileOffset = (descriptorFlags & fdflagAppend) == 0
        ? offset
        : file.length;
    final written = writeAtFrom(source, start, length, fileOffset);
    offset = fileOffset + written;
    return written;
  }

  @override
  int writeAtFrom(Uint8List source, int start, int length, int fileOffset) =>
      file.writeAtFrom(source, start, length, fileOffset);

  @override
  void setLength(int length) => file.setLength(length);

  @override
  void allocate(int offset, int length) => file.allocate(offset, length);

  @override
  void dataSync() {}

  @override
  void sync() {}

  @override
  void close() {}
}

final class Preview1VirtualSocket {
  Preview1VirtualSocket(
    this.socket, {
    Preview1DescriptorRights? rights,
    this.descriptorFlags = 0,
  }) : rights =
           rights ??
           Preview1DescriptorRights.socket(canAccept: socket.canAccept);

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

  /// Records a VFS-owned datagram message without another defensive copy.
  int writeOwnedMessage(Uint8List data) =>
      writeWASIPreview1SocketOwnedMessage(socket, data);

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

  int ensureReceiveData(
    int minUnreadBytes, {
    bool drainUntilSatisfied = false,
  }) => socket.ensureReceiveData(
    minUnreadBytes,
    drainUntilSatisfied: drainUntilSatisfied,
  );

  int? get readReadyBytes => socket.readReadyBytes;

  bool? get writeReady => socket.writeReady;

  bool get isDatagram => socket.isDatagram;

  bool get isStream => socket.isStream;

  bool get canAccept => socket.canAccept;

  bool get hasReceiveMessage => socket.hasReceiveMessage;

  bool get hasPendingAccept => socket.hasPendingAccept;

  int get nextReceiveMessageLength => socket.nextReceiveMessageLength;

  int get fileType =>
      socket.isDatagram ? filetypeSocketDgram : filetypeSocketStream;
}

enum Preview1VirtualOpenKind {
  file,
  directory,
  missing,
  exists,
  isDirectory,
  notDirectory,
  symlinkLoop,
  notCapable,
  notSupported,
}

enum Preview1PathMutationResult {
  success,
  invalid,
  noEntry,
  exists,
  isDirectory,
  notDirectory,
  notEmpty,
  notCapable,
  symlinkLoop,
  permissionDenied,
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

  const Preview1VirtualOpenResult.exists()
    : this._(Preview1VirtualOpenKind.exists, null);

  const Preview1VirtualOpenResult.isDirectory()
    : this._(Preview1VirtualOpenKind.isDirectory, null);

  const Preview1VirtualOpenResult.notDirectory()
    : this._(Preview1VirtualOpenKind.notDirectory, null);

  const Preview1VirtualOpenResult.symlinkLoop()
    : this._(Preview1VirtualOpenKind.symlinkLoop, null);

  const Preview1VirtualOpenResult.notCapable()
    : this._(Preview1VirtualOpenKind.notCapable, null);

  const Preview1VirtualOpenResult.notSupported()
    : this._(Preview1VirtualOpenKind.notSupported, null);

  final Preview1VirtualOpenKind kind;
  final int? fd;
}

final class Preview1ResolvedGuestPathInfo {
  const Preview1ResolvedGuestPathInfo({
    required this.path,
    required this.hasTrailingSeparator,
    required this.containsNul,
    required this.isAbsolute,
    required this.escapesPreopen,
  });

  final String path;
  final bool hasTrailingSeparator;
  final bool containsNul;
  final bool isAbsolute;
  final bool escapesPreopen;
}

final class Preview1SymlinkTargetInfo {
  const Preview1SymlinkTargetInfo({
    required this.target,
    required this.containsNul,
    required this.isAbsolute,
  });

  final String target;
  final bool containsNul;
  final bool isAbsolute;
}

Preview1ResolvedGuestPathInfo? resolveGuestPathInfo({
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
  return Preview1ResolvedGuestPathInfo(
    path: joinGuestPath(preopenPath, normalizedPath),
    hasTrailingSeparator: hasTrailingGuestPathSeparator(normalizedPath),
    containsNul: nul != -1,
    isAbsolute: isAbsoluteGuestPath(normalizedPath),
    escapesPreopen: guestPathEscapesPreopen(normalizedPath),
  );
}

Preview1SymlinkTargetInfo? resolveSymlinkTargetInfo({
  required Uint8List bytes,
  required int targetPtr,
  required int targetLen,
}) {
  if (targetPtr < 0 || targetLen < 0 || targetPtr + targetLen > bytes.length) {
    return null;
  }
  final decoded = utf8.decode(
    bytes.sublist(targetPtr, targetPtr + targetLen),
    allowMalformed: true,
  );
  return Preview1SymlinkTargetInfo(
    target: decoded,
    containsNul: decoded.contains('\u0000'),
    isAbsolute: isAbsoluteGuestPath(decoded),
  );
}

int? errnoForSymlinkTargetInfo(Preview1SymlinkTargetInfo info) {
  if (info.containsNul) {
    return errnoInval;
  }
  if (info.isAbsolute) {
    return errnoNotcapable;
  }
  return null;
}

String? resolveGuestPath({
  required Uint8List bytes,
  required String preopenPath,
  required int pathPtr,
  required int pathLen,
}) {
  final info = resolveGuestPathInfo(
    bytes: bytes,
    preopenPath: preopenPath,
    pathPtr: pathPtr,
    pathLen: pathLen,
  );
  if (info == null || errnoForResolvedGuestPathInfo(info) != null) {
    return null;
  }
  return info.path;
}

bool hasTrailingGuestPathSeparator(String path) {
  final sanitized = path.replaceAll('\\', '/');
  return sanitized.endsWith('/') && normalizeGuestPath(sanitized) != '/';
}

bool isAbsoluteGuestPath(String path) {
  return path.replaceAll('\\', '/').startsWith('/');
}

bool guestPathEscapesPreopen(String path) {
  final sanitized = path.replaceAll('\\', '/');
  if (sanitized.startsWith('/')) {
    return false;
  }
  var depth = 0;
  for (final segment in sanitized.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (depth == 0) {
        return true;
      }
      depth--;
      continue;
    }
    depth++;
  }
  return false;
}

int? errnoForResolvedGuestPathInfo(Preview1ResolvedGuestPathInfo info) {
  if (info.containsNul) {
    return errnoInval;
  }
  if (info.isAbsolute || info.escapesPreopen) {
    return errnoNotcapable;
  }
  return null;
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

Uint8List nulTerminated(String value) =>
    Uint8List.fromList(<int>[...utf8.encode(value), 0]);

Uint8List pathBytes(String value) => Uint8List.fromList(utf8.encode(value));

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

Preview1DescriptorRights _stdioRightsFor(Preview1StdioDescriptorKind kind) {
  const commonRights =
      rightFdFdstatSetFlags | rightFdFilestatGet | rightPollFdReadwrite;
  final directionRights = switch (kind) {
    Preview1StdioDescriptorKind.stdin => rightFdRead,
    Preview1StdioDescriptorKind.stdout ||
    Preview1StdioDescriptorKind.stderr => rightFdWrite,
  };
  return Preview1DescriptorRights(
    base: commonRights | directionRights,
    inheriting: 0,
  );
}

void _validateInitialDescriptorNamespace({
  required int firstVirtualFd,
  required int stdinFd,
  required int stdoutFd,
  required int stderrFd,
  required Iterable<int> preopenFds,
  required Iterable<int> socketFds,
}) {
  if (firstVirtualFd < 0) {
    throw ArgumentError.value(
      firstVirtualFd,
      'firstVirtualFd',
      'must not be negative',
    );
  }

  final stdioFds = <int>[stdinFd, stdoutFd, stderrFd];
  final seenStdio = <int>{};
  for (final fd in stdioFds) {
    if (fd < 0) {
      throw ArgumentError.value(fd, 'stdio fd', 'must not be negative');
    }
    if (!seenStdio.add(fd)) {
      throw ArgumentError.value(fd, 'stdio fd', 'must be unique');
    }
  }

  final seenPreopen = <int>{};
  for (final fd in preopenFds) {
    if (fd < 0) {
      throw ArgumentError.value(fd, 'preopen fd', 'must not be negative');
    }
    if (seenStdio.contains(fd)) {
      throw ArgumentError.value(
        fd,
        'preopen fd',
        'must not collide with stdio descriptors',
      );
    }
    seenPreopen.add(fd);
  }

  final reservedFds = <int>{...seenStdio, ...seenPreopen};
  for (final fd in socketFds) {
    if (fd < 0) {
      throw ArgumentError.value(fd, 'socket fd', 'must not be negative');
    }
    if (reservedFds.contains(fd)) {
      throw ArgumentError.value(
        fd,
        'socket fd',
        'must not collide with stdio or preopen descriptors',
      );
    }
  }
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
  required Map<String, Preview1VirtualNodeMetadata>
  directoryMetadataByGuestPath,
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
    required int inode,
  }) {
    final children = childrenByDirectory[parent];
    if (children == null || name.isEmpty) {
      return;
    }
    children.putIfAbsent(
      name,
      () =>
          Preview1DirectoryEntry(name: name, fileType: fileType, inode: inode),
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
      inode: directoryMetadataByGuestPath[directory]?.inode ?? 0,
    );
  }
  for (final entry in filesByGuestPath.entries) {
    addChild(
      parent: dirnameOfGuestPath(entry.key),
      name: basenameOfGuestPath(entry.key),
      fileType: filetypeRegularFile,
      inode: entry.value.metadata.inode,
    );
  }
  for (final entry in symlinksByGuestPath.entries) {
    addChild(
      parent: dirnameOfGuestPath(entry.key),
      name: basenameOfGuestPath(entry.key),
      fileType: filetypeSymbolicLink,
      inode: entry.value.metadata.inode,
    );
  }

  return childrenByDirectory;
}

Map<String, List<Preview1DirectoryEntry>> _buildDirectoryEntriesFromChildren(
  _DirectoryChildrenByPath childrenByDirectory, {
  required Map<String, Preview1VirtualNodeMetadata>
  directoryMetadataByGuestPath,
}) {
  return {
    for (final entry in childrenByDirectory.entries)
      entry.key: _directoryEntryList(
        directoryPath: entry.key,
        children: entry.value,
        directoryMetadataByGuestPath: directoryMetadataByGuestPath,
      ),
  };
}

List<Preview1DirectoryEntry> _directoryEntryList({
  required String directoryPath,
  required Map<String, Preview1DirectoryEntry> children,
  required Map<String, Preview1VirtualNodeMetadata>
  directoryMetadataByGuestPath,
}) {
  final current = normalizeGuestPath(directoryPath);
  final parent = dirnameOfGuestPath(current);
  return <Preview1DirectoryEntry>[
    Preview1DirectoryEntry(
      name: '.',
      fileType: filetypeDirectory,
      inode: directoryMetadataByGuestPath[current]?.inode ?? 0,
    ),
    Preview1DirectoryEntry(
      name: '..',
      fileType: filetypeDirectory,
      inode: directoryMetadataByGuestPath[parent]?.inode ?? 0,
    ),
    ...children.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
  ];
}

void _setUint64(ByteData data, int offset, int value) {
  if (value >= 0 && value <= _u32Max) {
    data.setUint32(offset, value, Endian.little);
    data.setUint32(offset + 4, 0, Endian.little);
    return;
  }
  final normalized = BigInt.from(value).toUnsigned(64);
  data.setUint32(offset, (normalized & _u32Mask).toInt(), Endian.little);
  data.setUint32(
    offset + 4,
    ((normalized >> 32) & _u32Mask).toInt(),
    Endian.little,
  );
}

const int _u32Max = 0xffffffff;
final BigInt _u32Mask = BigInt.from(_u32Max);
