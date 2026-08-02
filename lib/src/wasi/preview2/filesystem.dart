import 'dart:convert';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';
import 'io.dart';

/// Supplies the current entries for a filesystem directory.
typedef WASIPreview2FilesystemDirectoryEntriesProvider =
    Iterable<WASIPreview2FilesystemDirectoryEntry> Function();

/// Resolves one child entry by name without forcing a full directory scan.
typedef WASIPreview2FilesystemDirectoryEntryResolver =
    WASIPreview2FilesystemDirectoryEntry? Function(String name);

/// Reads regular-file bytes starting at a byte [offset].
typedef WASIPreview2FilesystemFileBytesProvider =
    Uint8List Function(BigInt offset);

/// Supplies the current byte length for a regular file.
typedef WASIPreview2FilesystemFileSizeProvider = BigInt Function();

/// Supplies current descriptor metadata for stat operations.
typedef WASIPreview2FilesystemMetadataProvider =
    WASIPreview2FilesystemMetadata Function();

/// Writes regular-file bytes starting at byte [offset].
typedef WASIPreview2FilesystemFileWriteCallback =
    WASIPreview2FilesystemMutationResult Function(
      BigInt offset,
      Uint8List bytes,
    );

/// Changes the byte length of a regular file.
typedef WASIPreview2FilesystemFileSetSizeCallback =
    WASIPreview2FilesystemMutationResult Function(BigInt size);

/// Synchronizes file contents to the backing store.
typedef WASIPreview2FilesystemFileSyncCallback =
    WASIPreview2FilesystemMutationResult Function();

/// Updates access and modification timestamps for one filesystem object.
typedef WASIPreview2FilesystemSetTimesCallback =
    WASIPreview2FilesystemMutationResult Function(
      WASIPreview2FilesystemTimestampUpdate update,
    );

/// Mutates one child entry inside a directory.
typedef WASIPreview2FilesystemDirectoryMutationCallback =
    WASIPreview2FilesystemMutationResult Function(String name);

/// Creates and returns one regular-file entry inside a directory.
typedef WASIPreview2FilesystemDirectoryFileCreateCallback =
    WASIPreview2FilesystemDirectoryEntry? Function(String name);

/// Links one child from this directory into [targetDirectory].
typedef WASIPreview2FilesystemDirectoryLinkCallback =
    WASIPreview2FilesystemMutationResult Function(
      String oldName,
      WASIPreview2FilesystemDirectory targetDirectory,
      String newName,
    );

/// Renames one child from this directory into [targetDirectory].
typedef WASIPreview2FilesystemDirectoryRenameCallback =
    WASIPreview2FilesystemMutationResult Function(
      String oldName,
      WASIPreview2FilesystemDirectory targetDirectory,
      String newName,
    );

/// Creates a symbolic link entry.
typedef WASIPreview2FilesystemDirectorySymlinkCallback =
    WASIPreview2FilesystemMutationResult Function(
      String target,
      String linkName,
    );

/// Reads a symbolic link target for a child entry.
typedef WASIPreview2FilesystemDirectoryReadLinkCallback =
    WASIPreview2FilesystemReadLinkResult Function(String name);

/// Filesystem mutation failures that map directly to WASI 0.2 error-code enum
/// cases.
enum WASIPreview2FilesystemMutationError {
  /// Host permission denied.
  access('access'),

  /// Operation would block.
  wouldBlock('would-block'),

  /// Target already exists.
  exist('exist'),

  /// Invalid path, offset, or argument.
  invalid('invalid'),

  /// Host I/O failure.
  io('io'),

  /// A directory was used where a regular file was required.
  isDirectory('is-directory'),

  /// Target path does not exist.
  noEntry('no-entry'),

  /// A non-directory was used where a directory was required.
  notDirectory('not-directory'),

  /// Directory removal targeted a non-empty directory.
  notEmpty('not-empty'),

  /// Path escaped the permitted preopen tree.
  notPermitted('not-permitted'),

  /// Descriptor or backing store is read-only.
  readOnly('read-only'),

  /// Operation is not supported by the host backing store.
  unsupported('unsupported');

  const WASIPreview2FilesystemMutationError(this.errorCode);

  /// WIT `error-code` enum label.
  final String errorCode;
}

/// Result returned by Preview2 filesystem mutation callbacks.
final class WASIPreview2FilesystemMutationResult {
  /// Creates a successful mutation result.
  const WASIPreview2FilesystemMutationResult.ok() : error = null;

  /// Creates a failed mutation result with a WASI filesystem [error].
  const WASIPreview2FilesystemMutationResult.error(this.error);

  /// WASI filesystem error reported by the mutation, or null on success.
  final WASIPreview2FilesystemMutationError? error;

  /// Whether the mutation succeeded.
  bool get isOk => error == null;
}

/// Timestamp update requested by WASI 0.2 filesystem operations.
final class WASIPreview2FilesystemTimestampUpdate {
  /// Creates a timestamp update.
  const WASIPreview2FilesystemTimestampUpdate({
    this.accessTimeNanos,
    this.modificationTimeNanos,
  });

  /// New access timestamp in nanoseconds since the Unix epoch.
  final BigInt? accessTimeNanos;

  /// New modification timestamp in nanoseconds since the Unix epoch.
  final BigInt? modificationTimeNanos;

  /// Whether either timestamp should change.
  bool get hasChanges =>
      accessTimeNanos != null || modificationTimeNanos != null;
}

/// Metadata returned by WASI 0.2 filesystem stat operations.
final class WASIPreview2FilesystemMetadata {
  /// Creates descriptor metadata.
  const WASIPreview2FilesystemMetadata({
    this.linkCount,
    this.size,
    this.objectIdentity,
    this.accessTimeNanos,
    this.modificationTimeNanos,
    this.statusChangeTimeNanos,
  });

  /// Number of hard links, or null when the backing store cannot report it.
  final BigInt? linkCount;

  /// Current byte size, or null to use the descriptor's existing size provider.
  final BigInt? size;

  /// Host-specific object identity used for `descriptor.is-same-object`.
  final String? objectIdentity;

  /// Access timestamp in nanoseconds since the Unix epoch.
  final BigInt? accessTimeNanos;

  /// Modification timestamp in nanoseconds since the Unix epoch.
  final BigInt? modificationTimeNanos;

  /// Status-change timestamp in nanoseconds since the Unix epoch.
  final BigInt? statusChangeTimeNanos;
}

/// Result returned by Preview2 filesystem readlink callbacks.
final class WASIPreview2FilesystemReadLinkResult {
  /// Creates a successful readlink result with [target].
  const WASIPreview2FilesystemReadLinkResult.ok(this.target) : error = null;

  /// Creates a failed readlink result with a WASI filesystem [error].
  const WASIPreview2FilesystemReadLinkResult.error(this.error) : target = null;

  /// Symbolic link target on success.
  final String? target;

  /// WASI filesystem error reported by the operation, or null on success.
  final WASIPreview2FilesystemMutationError? error;

  /// Whether the operation succeeded.
  bool get isOk => error == null;
}

/// WASI 0.2 filesystem object kind used by the Preview2 host.
enum WASIPreview2FilesystemDescriptorKind {
  /// Unknown descriptor kind.
  unknown,

  /// Directory descriptor.
  directory,

  /// Symbolic-link descriptor.
  symbolicLink,

  /// Regular-file descriptor.
  regularFile,
}

/// Directory contents exposed through a WASI 0.2 filesystem preopen.
final class WASIPreview2FilesystemDirectory {
  /// Creates a directory model with stable [entries].
  WASIPreview2FilesystemDirectory({
    Iterable<WASIPreview2FilesystemDirectoryEntry> entries =
        const <WASIPreview2FilesystemDirectoryEntry>[],
    this.canMutate = false,
    this.mutationContext,
    WASIPreview2FilesystemMetadataProvider? metadata,
    WASIPreview2FilesystemDirectoryMutationCallback? createDirectory,
    WASIPreview2FilesystemDirectoryFileCreateCallback? createFile,
    WASIPreview2FilesystemDirectoryLinkCallback? link,
    WASIPreview2FilesystemDirectoryRenameCallback? rename,
    WASIPreview2FilesystemDirectorySymlinkCallback? symlink,
    WASIPreview2FilesystemDirectoryReadLinkCallback? readLink,
    WASIPreview2FilesystemSetTimesCallback? setTimes,
    WASIPreview2FilesystemDirectoryMutationCallback? removeDirectory,
    WASIPreview2FilesystemDirectoryMutationCallback? unlinkFile,
    bool? createdFileCanMutate,
    bool? createdFileSupportsSync,
    bool? createdFileSupportsSyncData,
  }) : _entries = List<WASIPreview2FilesystemDirectoryEntry>.of(entries),
       createdFileCanMutate = createdFileCanMutate ?? canMutate,
       createdFileSupportsSync = createdFileSupportsSync ?? createFile == null,
       createdFileSupportsSyncData =
           createdFileSupportsSyncData ?? createFile == null,
       _entriesProvider = null,
       _entryResolver = null,
       _metadata = metadata,
       _createDirectory = createDirectory,
       _createFile = createFile,
       _link = link,
       _rename = rename,
       _symlink = symlink,
       _readLink = readLink,
       _setTimes = setTimes,
       _removeDirectory = removeDirectory,
       _unlinkFile = unlinkFile;

  /// Creates a directory whose contents are loaded from callbacks.
  WASIPreview2FilesystemDirectory.dynamic({
    required WASIPreview2FilesystemDirectoryEntriesProvider entries,
    WASIPreview2FilesystemDirectoryEntryResolver? resolveEntry,
    this.canMutate = false,
    this.mutationContext,
    WASIPreview2FilesystemMetadataProvider? metadata,
    WASIPreview2FilesystemDirectoryMutationCallback? createDirectory,
    WASIPreview2FilesystemDirectoryFileCreateCallback? createFile,
    WASIPreview2FilesystemDirectoryLinkCallback? link,
    WASIPreview2FilesystemDirectoryRenameCallback? rename,
    WASIPreview2FilesystemDirectorySymlinkCallback? symlink,
    WASIPreview2FilesystemDirectoryReadLinkCallback? readLink,
    WASIPreview2FilesystemSetTimesCallback? setTimes,
    WASIPreview2FilesystemDirectoryMutationCallback? removeDirectory,
    WASIPreview2FilesystemDirectoryMutationCallback? unlinkFile,
    bool? createdFileCanMutate,
    this.createdFileSupportsSync = false,
    this.createdFileSupportsSyncData = false,
  }) : _entries = <WASIPreview2FilesystemDirectoryEntry>[],
       createdFileCanMutate = createdFileCanMutate ?? canMutate,
       _entriesProvider = entries,
       _entryResolver = resolveEntry,
       _metadata = metadata,
       _createDirectory = createDirectory,
       _createFile = createFile,
       _link = link,
       _rename = rename,
       _symlink = symlink,
       _readLink = readLink,
       _setTimes = setTimes,
       _removeDirectory = removeDirectory,
       _unlinkFile = unlinkFile;

  /// Entries returned by `descriptor.read-directory`.
  List<WASIPreview2FilesystemDirectoryEntry> get entries =>
      List<WASIPreview2FilesystemDirectoryEntry>.unmodifiable(_currentEntries);

  /// Whether descriptors opened for this directory can request mutation flags.
  final bool canMutate;

  /// Whether files created by this directory can be opened for mutation.
  final bool createdFileCanMutate;

  /// Whether files created by this directory support `sync`.
  final bool createdFileSupportsSync;

  /// Whether files created by this directory support `sync-data`.
  final bool createdFileSupportsSyncData;

  /// Opaque host-specific context available to mutation callbacks.
  final Object? mutationContext;

  final List<WASIPreview2FilesystemDirectoryEntry> _entries;
  final WASIPreview2FilesystemDirectoryEntriesProvider? _entriesProvider;
  final WASIPreview2FilesystemDirectoryEntryResolver? _entryResolver;
  final WASIPreview2FilesystemMetadataProvider? _metadata;
  final WASIPreview2FilesystemDirectoryMutationCallback? _createDirectory;
  final WASIPreview2FilesystemDirectoryFileCreateCallback? _createFile;
  final WASIPreview2FilesystemDirectoryLinkCallback? _link;
  final WASIPreview2FilesystemDirectoryRenameCallback? _rename;
  final WASIPreview2FilesystemDirectorySymlinkCallback? _symlink;
  final WASIPreview2FilesystemDirectoryReadLinkCallback? _readLink;
  final WASIPreview2FilesystemSetTimesCallback? _setTimes;
  final WASIPreview2FilesystemDirectoryMutationCallback? _removeDirectory;
  final WASIPreview2FilesystemDirectoryMutationCallback? _unlinkFile;

  Iterable<WASIPreview2FilesystemDirectoryEntry> get _currentEntries {
    final provider = _entriesProvider;
    return provider == null ? _entries : provider();
  }

  WASIPreview2FilesystemDirectoryEntry? _entryNamed(String name) {
    final resolver = _entryResolver;
    if (resolver != null) {
      return resolver(name);
    }
    for (final entry in _currentEntries) {
      if (entry.name == name) {
        return entry;
      }
    }
    return null;
  }

  WASIPreview2FilesystemMutationResult _createDirectoryAt(String name) {
    if (!canMutate) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(name)) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final callback = _createDirectory;
    if (callback != null) {
      return callback(name);
    }
    if (_entriesProvider != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (_entryNamed(name) != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.exist,
      );
    }
    _entries.add(
      WASIPreview2FilesystemDirectoryEntry.directory(
        name,
        directory: WASIPreview2FilesystemDirectory(canMutate: canMutate),
      ),
    );
    return const WASIPreview2FilesystemMutationResult.ok();
  }

  ({
    WASIPreview2FilesystemDirectoryEntry? entry,
    WASIPreview2FilesystemMutationResult result,
  })
  _createFileAt(String name) {
    if (!canMutate) {
      return (
        entry: null,
        result: const WASIPreview2FilesystemMutationResult.error(
          WASIPreview2FilesystemMutationError.readOnly,
        ),
      );
    }
    if (!_isSimplePathSegment(name)) {
      return (
        entry: null,
        result: const WASIPreview2FilesystemMutationResult.error(
          WASIPreview2FilesystemMutationError.invalid,
        ),
      );
    }
    if (_entryNamed(name) != null) {
      return (
        entry: null,
        result: const WASIPreview2FilesystemMutationResult.error(
          WASIPreview2FilesystemMutationError.exist,
        ),
      );
    }
    final callback = _createFile;
    if (callback != null) {
      final entry = callback(name);
      return entry == null
          ? (
              entry: null,
              result: const WASIPreview2FilesystemMutationResult.error(
                WASIPreview2FilesystemMutationError.io,
              ),
            )
          : (
              entry: entry,
              result: const WASIPreview2FilesystemMutationResult.ok(),
            );
    }
    if (_entriesProvider != null) {
      return (
        entry: null,
        result: const WASIPreview2FilesystemMutationResult.error(
          WASIPreview2FilesystemMutationError.readOnly,
        ),
      );
    }
    final entry = WASIPreview2FilesystemDirectoryEntry.regularFile(
      name,
      canMutate: canMutate,
    );
    _entries.add(entry);
    return (
      entry: entry,
      result: const WASIPreview2FilesystemMutationResult.ok(),
    );
  }

  WASIPreview2FilesystemMutationResult _removeDirectoryAt(String name) {
    if (!canMutate) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(name)) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final entry = _entryNamed(name);
    if (entry == null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.noEntry,
      );
    }
    if (entry.kind != WASIPreview2FilesystemDescriptorKind.directory) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.notDirectory,
      );
    }
    if (entry.directory!._currentEntries.isNotEmpty) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.notEmpty,
      );
    }
    final callback = _removeDirectory;
    if (callback != null) {
      return callback(name);
    }
    if (_entriesProvider != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    _entries.removeWhere((candidate) => candidate.name == name);
    return const WASIPreview2FilesystemMutationResult.ok();
  }

  WASIPreview2FilesystemMutationResult _setTimesTo(
    WASIPreview2FilesystemTimestampUpdate update,
  ) {
    if (!canMutate) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (!update.hasChanges) {
      return const WASIPreview2FilesystemMutationResult.ok();
    }
    final callback = _setTimes;
    if (callback != null) {
      return callback(update);
    }
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.readOnly,
    );
  }

  WASIPreview2FilesystemMetadata? _currentMetadata() => _metadata?.call();

  WASIPreview2FilesystemMutationResult _linkAt(
    String oldName,
    WASIPreview2FilesystemDirectory targetDirectory,
    String newName,
  ) {
    if (!targetDirectory.canMutate) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(oldName) || !_isSimplePathSegment(newName)) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final callback = _link;
    if (callback != null) {
      return callback(oldName, targetDirectory, newName);
    }
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.readOnly,
    );
  }

  WASIPreview2FilesystemMutationResult _renameAt(
    String oldName,
    WASIPreview2FilesystemDirectory targetDirectory,
    String newName,
  ) {
    if (!canMutate || !targetDirectory.canMutate) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(oldName) || !_isSimplePathSegment(newName)) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final callback = _rename;
    if (callback != null) {
      return callback(oldName, targetDirectory, newName);
    }
    if (_entriesProvider != null || targetDirectory._entriesProvider != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    final entry = _entryNamed(oldName);
    if (entry == null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.noEntry,
      );
    }
    if (targetDirectory._entryNamed(newName) != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.exist,
      );
    }
    _entries.removeWhere((candidate) => candidate.name == oldName);
    targetDirectory._entries.add(entry._renamed(newName));
    return const WASIPreview2FilesystemMutationResult.ok();
  }

  WASIPreview2FilesystemMutationResult _symlinkAt(
    String target,
    String linkName,
  ) {
    if (!canMutate) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (target.contains('\u0000') || !_isSimplePathSegment(linkName)) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final callback = _symlink;
    if (callback != null) {
      return callback(target, linkName);
    }
    if (_entriesProvider != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (_entryNamed(linkName) != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.exist,
      );
    }
    _entries.add(
      WASIPreview2FilesystemDirectoryEntry.symbolicLink(
        linkName,
        target: target,
      ),
    );
    return const WASIPreview2FilesystemMutationResult.ok();
  }

  WASIPreview2FilesystemReadLinkResult _readLinkAt(String name) {
    if (!_isSimplePathSegment(name)) {
      return const WASIPreview2FilesystemReadLinkResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final callback = _readLink;
    if (callback != null) {
      return callback(name);
    }
    final entry = _entryNamed(name);
    if (entry == null) {
      return const WASIPreview2FilesystemReadLinkResult.error(
        WASIPreview2FilesystemMutationError.noEntry,
      );
    }
    final target = entry._linkTarget;
    if (entry.kind != WASIPreview2FilesystemDescriptorKind.symbolicLink ||
        target == null) {
      return const WASIPreview2FilesystemReadLinkResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    return WASIPreview2FilesystemReadLinkResult.ok(target);
  }

  WASIPreview2FilesystemMutationResult _unlinkFileAt(String name) {
    if (!canMutate) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(name)) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final entry = _entryNamed(name);
    if (entry == null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.noEntry,
      );
    }
    if (entry.kind == WASIPreview2FilesystemDescriptorKind.directory) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.isDirectory,
      );
    }
    final callback = _unlinkFile;
    if (callback != null) {
      return callback(name);
    }
    if (_entriesProvider != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    _entries.removeWhere((candidate) => candidate.name == name);
    return const WASIPreview2FilesystemMutationResult.ok();
  }
}

/// One directory entry exposed by [WASIPreview2FilesystemDirectory].
final class WASIPreview2FilesystemDirectoryEntry {
  /// Creates a directory entry.
  WASIPreview2FilesystemDirectoryEntry.directory(
    this.name, {
    WASIPreview2FilesystemDirectory? directory,
    WASIPreview2FilesystemMetadataProvider? metadata,
  }) : kind = WASIPreview2FilesystemDescriptorKind.directory,
       size = BigInt.zero,
       directory = directory ?? WASIPreview2FilesystemDirectory(),
       canMutate = directory?.canMutate ?? false,
       _bytes = Uint8List(0),
       _readBytes = null,
       _currentSize = null,
       _metadata = metadata,
       _writeBytes = null,
       _setSize = null,
       _syncData = null,
       _sync = null,
       _setTimes = null,
       _linkTarget = null;

  /// Creates a symbolic-link entry.
  WASIPreview2FilesystemDirectoryEntry.symbolicLink(
    this.name, {
    required String target,
    WASIPreview2FilesystemMetadataProvider? metadata,
  }) : kind = WASIPreview2FilesystemDescriptorKind.symbolicLink,
       size = BigInt.from(utf8.encode(target).length),
       directory = null,
       canMutate = false,
       _bytes = Uint8List(0),
       _readBytes = null,
       _currentSize = null,
       _metadata = metadata,
       _writeBytes = null,
       _setSize = null,
       _syncData = null,
       _sync = null,
       _setTimes = null,
       _linkTarget = target;

  /// Creates a regular-file entry.
  WASIPreview2FilesystemDirectoryEntry.regularFile(
    this.name, {
    BigInt? size,
    List<int> bytes = const <int>[],
    this.canMutate = false,
    WASIPreview2FilesystemFileBytesProvider? readBytes,
    WASIPreview2FilesystemFileSizeProvider? currentSize,
    WASIPreview2FilesystemMetadataProvider? metadata,
    WASIPreview2FilesystemFileWriteCallback? writeBytes,
    WASIPreview2FilesystemFileSetSizeCallback? setSize,
    WASIPreview2FilesystemFileSyncCallback? syncData,
    WASIPreview2FilesystemFileSyncCallback? sync,
    WASIPreview2FilesystemSetTimesCallback? setTimes,
  }) : _bytes = Uint8List.fromList(bytes),
       _readBytes = readBytes,
       _currentSize = currentSize,
       _metadata = metadata,
       _writeBytes = writeBytes,
       _setSize = setSize,
       _syncData = syncData,
       _sync = sync,
       _setTimes = setTimes,
       _linkTarget = null,
       kind = WASIPreview2FilesystemDescriptorKind.regularFile,
       size = size ?? currentSize?.call() ?? BigInt.from(bytes.length),
       directory = null;

  /// Entry name relative to the containing directory.
  final String name;

  /// Entry kind.
  final WASIPreview2FilesystemDescriptorKind kind;

  /// File size for regular files.
  final BigInt size;

  /// Nested directory contents for directory entries.
  final WASIPreview2FilesystemDirectory? directory;

  /// Whether this entry can be opened with mutation flags.
  final bool canMutate;

  /// Immutable snapshot of current file contents.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  Uint8List _bytes;
  final WASIPreview2FilesystemFileBytesProvider? _readBytes;
  final WASIPreview2FilesystemFileSizeProvider? _currentSize;
  final WASIPreview2FilesystemMetadataProvider? _metadata;
  final WASIPreview2FilesystemFileWriteCallback? _writeBytes;
  final WASIPreview2FilesystemFileSetSizeCallback? _setSize;
  final WASIPreview2FilesystemFileSyncCallback? _syncData;
  final WASIPreview2FilesystemFileSyncCallback? _sync;
  final WASIPreview2FilesystemSetTimesCallback? _setTimes;
  final String? _linkTarget;

  BigInt get _size =>
      _currentSize?.call() ??
      (kind == WASIPreview2FilesystemDescriptorKind.symbolicLink
          ? size
          : BigInt.from(_bytes.length));

  WASIPreview2FilesystemMetadata? _currentMetadata() {
    final metadata = _metadata?.call();
    if (metadata != null) {
      return metadata;
    }
    if (kind == WASIPreview2FilesystemDescriptorKind.directory) {
      return directory?._currentMetadata();
    }
    return null;
  }

  Uint8List _bytesFrom(BigInt offset) {
    final reader = _readBytes;
    if (reader != null) {
      return reader(offset);
    }
    final start = offset > BigInt.from(_bytes.length)
        ? _bytes.length
        : offset.toInt();
    return _bytes.sublist(start);
  }

  WASIPreview2FilesystemMutationResult _writeAt(BigInt offset, Uint8List data) {
    if (kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.isDirectory,
      );
    }
    if (offset < BigInt.zero) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final callback = _writeBytes;
    if (callback != null) {
      return callback(offset, Uint8List.fromList(data));
    }
    if (!canMutate || _readBytes != null || _currentSize != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    final start = offset.toInt();
    final end = start + data.length;
    if (end > _bytes.length) {
      final resized = Uint8List(end);
      resized.setAll(0, _bytes);
      _bytes = resized;
    }
    _bytes.setRange(start, end, data);
    return const WASIPreview2FilesystemMutationResult.ok();
  }

  WASIPreview2FilesystemMutationResult _setSizeTo(BigInt nextSize) {
    if (kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.isDirectory,
      );
    }
    if (nextSize < BigInt.zero) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.invalid,
      );
    }
    final callback = _setSize;
    if (callback != null) {
      return callback(nextSize);
    }
    if (!canMutate || _readBytes != null || _currentSize != null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    final length = nextSize.toInt();
    final resized = Uint8List(length);
    final preserved = length < _bytes.length ? length : _bytes.length;
    resized.setRange(0, preserved, _bytes);
    _bytes = resized;
    return const WASIPreview2FilesystemMutationResult.ok();
  }

  WASIPreview2FilesystemMutationResult _setTimesTo(
    WASIPreview2FilesystemTimestampUpdate update,
  ) {
    if (!canMutate) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    if (!update.hasChanges) {
      return const WASIPreview2FilesystemMutationResult.ok();
    }
    if (kind == WASIPreview2FilesystemDescriptorKind.directory) {
      return directory!._setTimesTo(update);
    }
    if (kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.unsupported,
      );
    }
    final callback = _setTimes;
    if (callback != null) {
      return callback(update);
    }
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.readOnly,
    );
  }

  WASIPreview2FilesystemMutationResult _syncDataTo() {
    if (kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.unsupported,
      );
    }
    final callback = _syncData;
    if (callback != null) {
      return callback();
    }
    if (_readBytes == null && _currentSize == null) {
      return const WASIPreview2FilesystemMutationResult.ok();
    }
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.unsupported,
    );
  }

  bool get _supportsSyncData =>
      kind == WASIPreview2FilesystemDescriptorKind.regularFile &&
      (_syncData != null || _readBytes == null && _currentSize == null);

  WASIPreview2FilesystemMutationResult _syncTo() {
    if (kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.unsupported,
      );
    }
    final callback = _sync;
    if (callback != null) {
      return callback();
    }
    if (_readBytes == null && _currentSize == null) {
      return const WASIPreview2FilesystemMutationResult.ok();
    }
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.unsupported,
    );
  }

  bool get _supportsSync =>
      kind == WASIPreview2FilesystemDescriptorKind.regularFile &&
      (_sync != null || _readBytes == null && _currentSize == null);

  WASIPreview2FilesystemDirectoryEntry _renamed(String name) {
    return switch (kind) {
      WASIPreview2FilesystemDescriptorKind.directory =>
        WASIPreview2FilesystemDirectoryEntry.directory(
          name,
          directory: directory,
          metadata: _metadata,
        ),
      WASIPreview2FilesystemDescriptorKind.symbolicLink =>
        WASIPreview2FilesystemDirectoryEntry.symbolicLink(
          name,
          target: _linkTarget ?? '',
          metadata: _metadata,
        ),
      WASIPreview2FilesystemDescriptorKind.regularFile =>
        WASIPreview2FilesystemDirectoryEntry.regularFile(
          name,
          size: size,
          bytes: _bytes,
          canMutate: canMutate,
          readBytes: _readBytes,
          currentSize: _currentSize,
          metadata: _metadata,
          writeBytes: _writeBytes,
          setSize: _setSize,
          syncData: _syncData,
          sync: _sync,
          setTimes: _setTimes,
        ),
      WASIPreview2FilesystemDescriptorKind.unknown =>
        WASIPreview2FilesystemDirectoryEntry.regularFile(
          name,
          bytes: _bytes,
          canMutate: canMutate,
        ),
    };
  }
}

/// WASI 0.2 `wasi:filesystem` host imports.
base class WASIPreview2FilesystemHost {
  /// Creates a filesystem host with preopened guest directories.
  WASIPreview2FilesystemHost({
    Map<String, WASIPreview2FilesystemDirectory> preopens =
        const <String, WASIPreview2FilesystemDirectory>{},
    WASIComponentResourceTable? table,
    WASIPreview2StreamsHost? streamsHost,
  }) : this._(
         preopens: preopens,
         streamsHost: _resolveStreamsHost(table, streamsHost),
       );

  WASIPreview2FilesystemHost._({
    required Map<String, WASIPreview2FilesystemDirectory> preopens,
    required this.streamsHost,
  }) : table = streamsHost.table {
    for (final entry in preopens.entries) {
      final guestPath = _normalizePreopenPath(entry.key);
      final descriptor = _WASIPreview2FilesystemDescriptor.directory(
        objectId: _nextObjectId++,
        guestPath: guestPath,
        directory: entry.value,
      );
      _preopens.add((descriptor, guestPath));
    }
  }

  static WASIPreview2StreamsHost _resolveStreamsHost(
    WASIComponentResourceTable? table,
    WASIPreview2StreamsHost? streamsHost,
  ) {
    final resolvedTable = table ?? streamsHost?.table;
    final resolvedStreamsHost =
        streamsHost ?? WASIPreview2StreamsHost(table: resolvedTable);
    if (resolvedTable != null &&
        !identical(resolvedTable, resolvedStreamsHost.table)) {
      throw ArgumentError.value(
        streamsHost,
        'streamsHost',
        'must use the same component resource table as filesystem',
      );
    }
    return resolvedStreamsHost;
  }

  /// Component resource table that owns filesystem and stream handles.
  final WASIComponentResourceTable table;

  /// Streams host used by file read/write stream operations.
  final WASIPreview2StreamsHost streamsHost;

  late final WASIComponentResourceType<_WASIPreview2FilesystemDescriptor>
  _descriptorType = table.defineType<_WASIPreview2FilesystemDescriptor>(
    'wasi:filesystem/types@0.2.0.descriptor',
  );

  late final WASIComponentResourceType<_WASIPreview2DirectoryEntryStream>
  _directoryEntryStreamType = table
      .defineType<_WASIPreview2DirectoryEntryStream>(
        'wasi:filesystem/types@0.2.0.directory-entry-stream',
      );

  int _nextObjectId = 1;
  final _preopens = <(_WASIPreview2FilesystemDescriptor, String)>[];

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback>
  imports = Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
    'wasi:filesystem/preopens@0.2.0.get-directories': (_) => _getDirectories(),
    'wasi:filesystem/types@0.2.0.descriptor.read-via-stream': (args) =>
        _readViaStream(_handle(args[0]), _u64(args[1])),
    'wasi:filesystem/types@0.2.0.descriptor.write-via-stream': (args) =>
        _writeViaStream(_handle(args[0]), _u64(args[1]), append: false),
    'wasi:filesystem/types@0.2.0.descriptor.append-via-stream': (args) =>
        _writeViaStream(_handle(args[0]), BigInt.zero, append: true),
    'wasi:filesystem/types@0.2.0.descriptor.advise': (args) =>
        _unitResultForDescriptor(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.descriptor.sync-data': (args) =>
        _syncData(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.descriptor.get-flags': (args) =>
        _getFlags(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.descriptor.get-type': (args) =>
        _getType(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.descriptor.set-size': (args) =>
        _setSize(_handle(args[0]), _u64(args[1])),
    'wasi:filesystem/types@0.2.0.descriptor.set-times': (args) =>
        _setTimes(_handle(args[0]), args[1], args[2]),
    'wasi:filesystem/types@0.2.0.descriptor.read': (args) =>
        _read(_handle(args[0]), _u64(args[1]), _u64(args[2])),
    'wasi:filesystem/types@0.2.0.descriptor.write': (args) =>
        _write(_handle(args[0]), _u8List(args[1]), _u64(args[2])),
    'wasi:filesystem/types@0.2.0.descriptor.read-directory': (args) =>
        _readDirectory(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.descriptor.sync': (args) =>
        _sync(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.descriptor.create-directory-at': (args) =>
        _createDirectoryAt(_handle(args[0]), args[1] as String),
    'wasi:filesystem/types@0.2.0.descriptor.stat': (args) =>
        _stat(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.descriptor.stat-at': (args) => _statAt(
      _handle(args[0]),
      args[1] as WasmComponentValueData,
      args[2] as String,
    ),
    'wasi:filesystem/types@0.2.0.descriptor.set-times-at': (args) =>
        _setTimesAt(
          _handle(args[0]),
          args[1] as WasmComponentValueData,
          args[2] as String,
          args[3],
          args[4],
        ),
    'wasi:filesystem/types@0.2.0.descriptor.link-at': (args) => _linkAt(
      _handle(args[0]),
      args[1] as WasmComponentValueData,
      args[2] as String,
      _handle(args[3]),
      args[4] as String,
    ),
    'wasi:filesystem/types@0.2.0.descriptor.open-at': (args) => _openAt(
      _handle(args[0]),
      args[1] as WasmComponentValueData,
      args[2] as String,
      args[3] as WasmComponentValueData,
      args[4] as WasmComponentValueData,
    ),
    'wasi:filesystem/types@0.2.0.descriptor.readlink-at': (args) =>
        _readLinkAt(_handle(args[0]), args[1] as String),
    'wasi:filesystem/types@0.2.0.descriptor.remove-directory-at': (args) =>
        _removeDirectoryAt(_handle(args[0]), args[1] as String),
    'wasi:filesystem/types@0.2.0.descriptor.rename-at': (args) => _renameAt(
      _handle(args[0]),
      args[1] as String,
      _handle(args[2]),
      args[3] as String,
    ),
    'wasi:filesystem/types@0.2.0.descriptor.symlink-at': (args) =>
        _symlinkAt(_handle(args[0]), args[1] as String, args[2] as String),
    'wasi:filesystem/types@0.2.0.descriptor.unlink-file-at': (args) =>
        _unlinkFileAt(_handle(args[0]), args[1] as String),
    'wasi:filesystem/types@0.2.0.descriptor.is-same-object': (args) =>
        _isSameObject(_handle(args[0]), _handle(args[1])),
    'wasi:filesystem/types@0.2.0.descriptor.metadata-hash': (args) =>
        _metadataHash(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.descriptor.metadata-hash-at': (args) =>
        _metadataHashAt(
          _handle(args[0]),
          args[1] as WasmComponentValueData,
          args[2] as String,
        ),
    'wasi:filesystem/types@0.2.0.directory-entry-stream.read-directory-entry':
        (args) => _readDirectoryEntry(_handle(args[0])),
    'wasi:filesystem/types@0.2.0.filesystem-error-code': (args) =>
        _filesystemErrorCode(_handle(args[0])),
  });

  int _insertDescriptor(_WASIPreview2FilesystemDescriptor descriptor) {
    return table.insert<_WASIPreview2FilesystemDescriptor>(
      _descriptorType,
      descriptor,
    );
  }

  _WASIPreview2FilesystemDescriptor? _descriptor(int handle) {
    try {
      return table.get<_WASIPreview2FilesystemDescriptor>(
        _descriptorType,
        handle,
      );
    } on StateError {
      return null;
    }
  }

  WasmComponentValueData _getDirectories() {
    return _list([
      for (final (descriptor, guestPath) in _preopens)
        _tuple(<WasmComponentValueData>[
          _integerData(_insertDescriptor(descriptor)),
          _stringData(guestPath),
        ]),
    ]);
  }

  WasmComponentValueData _readViaStream(int handle, BigInt offset) {
    final descriptor = _descriptor(handle);
    final error = _readableDescriptorError(descriptor);
    if (error != null) {
      return _errorResult(error);
    }
    final input = streamsHost.insertInputStream(
      WASIPreview2InputStream(
        bytes: descriptor!.bytesFrom(offset),
        closed: true,
      ),
    );
    return _ok(_integerData(input));
  }

  WasmComponentValueData _writeViaStream(
    int handle,
    BigInt offset, {
    required bool append,
  }) {
    final descriptor = _descriptor(handle);
    final error = _writableDescriptorError(descriptor);
    if (error != null) {
      return _errorResult(error);
    }
    var writeOffset = append ? descriptor!.currentSize : offset;
    final output = streamsHost.insertOutputStream(
      WASIPreview2OutputStream(
        onWrite: (bytes) {
          final mutation = descriptor!.writeAt(writeOffset, bytes);
          if (!mutation.isOk) {
            return mutation.error!.errorCode;
          }
          writeOffset += BigInt.from(bytes.length);
          return null;
        },
      ),
    );
    return _ok(_integerData(output));
  }

  String? _readableDescriptorError(
    _WASIPreview2FilesystemDescriptor? descriptor,
  ) {
    if (descriptor == null) {
      return 'bad-descriptor';
    }
    if (descriptor.kind == WASIPreview2FilesystemDescriptorKind.directory) {
      return 'is-directory';
    }
    if (descriptor.kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return 'invalid';
    }
    if (!descriptor.flags.contains('read')) {
      return 'not-permitted';
    }
    return null;
  }

  String? _writableDescriptorError(
    _WASIPreview2FilesystemDescriptor? descriptor,
  ) {
    if (descriptor == null) {
      return 'bad-descriptor';
    }
    if (descriptor.kind == WASIPreview2FilesystemDescriptorKind.directory) {
      return 'is-directory';
    }
    if (descriptor.kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return 'invalid';
    }
    if (!descriptor.canMutate || !descriptor.flags.contains('write')) {
      return 'read-only';
    }
    return null;
  }

  String? _mutableDirectoryDescriptorError(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return 'bad-descriptor';
    }
    if (descriptor.directory == null) {
      return 'not-directory';
    }
    if (!descriptor.canMutate ||
        !descriptor.flags.contains('mutate-directory')) {
      return 'read-only';
    }
    return null;
  }

  WasmComponentValueData _unitResultForDescriptor(int handle) {
    return _descriptor(handle) == null ? _errorResult('bad-descriptor') : _ok();
  }

  WasmComponentValueData _syncData(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    if (descriptor.kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return _errorResult('unsupported');
    }
    if (!descriptor.flags.contains('write')) {
      return _ok();
    }
    return _mutationResult(descriptor.syncData());
  }

  WasmComponentValueData _sync(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    if (descriptor.kind != WASIPreview2FilesystemDescriptorKind.regularFile) {
      return _errorResult('unsupported');
    }
    if (!descriptor.flags.contains('write')) {
      return _ok();
    }
    return _mutationResult(descriptor.sync());
  }

  WasmComponentValueData _getFlags(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(
      _flagsData([
        for (final flag in _descriptorFlagOrder)
          if (descriptor.flags.contains(flag)) flag,
      ]),
    );
  }

  WasmComponentValueData _setSize(int handle, BigInt size) {
    final descriptor = _descriptor(handle);
    final error = _writableDescriptorError(descriptor);
    if (error != null) {
      return _errorResult(error);
    }
    return _mutationResult(descriptor!.setSize(size));
  }

  WasmComponentValueData _setTimes(
    int handle,
    Object? accessTimestamp,
    Object? modificationTimestamp,
  ) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    final update = _timestampUpdate(accessTimestamp, modificationTimestamp);
    final error = update.error;
    if (error != null) {
      return _errorResult(error);
    }
    final mutationAllowed =
        descriptor.kind == WASIPreview2FilesystemDescriptorKind.directory
        ? descriptor.flags.contains('mutate-directory')
        : descriptor.flags.contains('write');
    if (!descriptor.canMutate || !mutationAllowed) {
      return _errorResult('read-only');
    }
    return _mutationResult(descriptor.setTimes(update.update!));
  }

  WasmComponentValueData _getType(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_descriptorTypeData(descriptor.kind));
  }

  WasmComponentValueData _read(int handle, BigInt length, BigInt offset) {
    final descriptor = _descriptor(handle);
    final error = _readableDescriptorError(descriptor);
    if (error != null) {
      return _errorResult(error);
    }
    final bytes = descriptor!.bytesFrom(offset);
    final count = _boundedLength(length, bytes.length);
    final chunk = bytes.sublist(0, count);
    final eof = offset + BigInt.from(count) >= descriptor.currentSize;
    return _ok(
      _tuple(<WasmComponentValueData>[_u8ListData(chunk), _bool(eof)]),
    );
  }

  WasmComponentValueData _write(int handle, List<int> bytes, BigInt offset) {
    final descriptor = _descriptor(handle);
    final error = _writableDescriptorError(descriptor);
    if (error != null) {
      return _errorResult(error);
    }
    final mutation = descriptor!.writeAt(offset, Uint8List.fromList(bytes));
    if (!mutation.isOk) {
      return _mutationResult(mutation);
    }
    return _ok(_integerData(BigInt.from(bytes.length)));
  }

  WasmComponentValueData _readDirectory(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    final directory = descriptor.directory;
    if (directory == null) {
      return _errorResult('not-directory');
    }
    if (!descriptor.flags.contains('read')) {
      return _errorResult('not-permitted');
    }
    final stream = table.insert<_WASIPreview2DirectoryEntryStream>(
      _directoryEntryStreamType,
      _WASIPreview2DirectoryEntryStream(directory.entries),
    );
    return _ok(_integerData(stream));
  }

  WasmComponentValueData _readDirectoryEntry(int handle) {
    final stream = _directoryEntryStream(handle);
    if (stream == null) {
      return _errorResult('bad-descriptor');
    }
    final entry = stream.read();
    return _ok(entry == null ? _none() : _some(_directoryEntryData(entry)));
  }

  _WASIPreview2DirectoryEntryStream? _directoryEntryStream(int handle) {
    try {
      return table.get<_WASIPreview2DirectoryEntryStream>(
        _directoryEntryStreamType,
        handle,
      );
    } on StateError {
      return null;
    }
  }

  WasmComponentValueData _stat(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_descriptorStatData(descriptor));
  }

  WasmComponentValueData _statAt(
    int handle,
    WasmComponentValueData flags,
    String path,
  ) {
    final resolved = _resolveAtResult(
      handle,
      path,
      followFinalSymlink: flags.labels.contains('symlink-follow'),
    );
    final error = resolved.error;
    return error == null
        ? _ok(_descriptorStatData(resolved.descriptor!))
        : _errorResult(error);
  }

  WasmComponentValueData _createDirectoryAt(int handle, String path) {
    final descriptorError = _mutableDirectoryDescriptorError(handle);
    if (descriptorError != null) {
      return _errorResult(descriptorError);
    }
    final target = _resolveMutationParent(handle, path);
    final error = target.error;
    if (error != null) {
      return _errorResult(error);
    }
    final parent = target.parent!;
    if (!parent.canMutate) {
      return _errorResult('read-only');
    }
    return _mutationResult(parent.directory!._createDirectoryAt(target.name));
  }

  WasmComponentValueData _setTimesAt(
    int handle,
    WasmComponentValueData flags,
    String path,
    Object? accessTimestamp,
    Object? modificationTimestamp,
  ) {
    final descriptorError = _mutableDirectoryDescriptorError(handle);
    if (descriptorError != null) {
      return _errorResult(descriptorError);
    }
    final update = _timestampUpdate(accessTimestamp, modificationTimestamp);
    final updateError = update.error;
    if (updateError != null) {
      return _errorResult(updateError);
    }
    final resolved = _resolveAtResult(
      handle,
      path,
      followFinalSymlink: flags.labels.contains('symlink-follow'),
    );
    final resolvedError = resolved.error;
    if (resolvedError != null) {
      return _errorResult(resolvedError);
    }
    return _mutationResult(resolved.descriptor!.setTimes(update.update!));
  }

  WasmComponentValueData _removeDirectoryAt(int handle, String path) {
    final descriptorError = _mutableDirectoryDescriptorError(handle);
    if (descriptorError != null) {
      return _errorResult(descriptorError);
    }
    final target = _resolveMutationParent(handle, path);
    final error = target.error;
    if (error != null) {
      return _errorResult(error);
    }
    final parent = target.parent!;
    if (!parent.canMutate) {
      return _errorResult('read-only');
    }
    return _mutationResult(parent.directory!._removeDirectoryAt(target.name));
  }

  WasmComponentValueData _unlinkFileAt(int handle, String path) {
    final descriptorError = _mutableDirectoryDescriptorError(handle);
    if (descriptorError != null) {
      return _errorResult(descriptorError);
    }
    final target = _resolveMutationParent(handle, path);
    final error = target.error;
    if (error != null) {
      return _errorResult(error);
    }
    final parent = target.parent!;
    if (!parent.canMutate) {
      return _errorResult('read-only');
    }
    return _mutationResult(parent.directory!._unlinkFileAt(target.name));
  }

  WasmComponentValueData _linkAt(
    int oldHandle,
    WasmComponentValueData oldPathFlags,
    String oldPath,
    int newHandle,
    String newPath,
  ) {
    final targetDescriptorError = _mutableDirectoryDescriptorError(newHandle);
    if (targetDescriptorError != null) {
      return _errorResult(targetDescriptorError);
    }
    final source = _resolveExistingMutationTarget(
      oldHandle,
      oldPath,
      followFinalSymlink: oldPathFlags.labels.contains('symlink-follow'),
    );
    final sourceError = source.error;
    if (sourceError != null) {
      return _errorResult(sourceError);
    }
    final target = _resolveMutationParent(newHandle, newPath);
    final targetError = target.error;
    if (targetError != null) {
      return _errorResult(targetError);
    }
    final targetParent = target.parent!;
    if (!targetParent.canMutate) {
      return _errorResult('read-only');
    }
    return _mutationResult(
      source.parent!.directory!._linkAt(
        source.name,
        targetParent.directory!,
        target.name,
      ),
    );
  }

  WasmComponentValueData _renameAt(
    int oldHandle,
    String oldPath,
    int newHandle,
    String newPath,
  ) {
    final sourceDescriptorError = _mutableDirectoryDescriptorError(oldHandle);
    if (sourceDescriptorError != null) {
      return _errorResult(sourceDescriptorError);
    }
    final targetDescriptorError = _mutableDirectoryDescriptorError(newHandle);
    if (targetDescriptorError != null) {
      return _errorResult(targetDescriptorError);
    }
    final source = _resolveMutationParent(oldHandle, oldPath);
    final sourceError = source.error;
    if (sourceError != null) {
      return _errorResult(sourceError);
    }
    final target = _resolveMutationParent(newHandle, newPath);
    final targetError = target.error;
    if (targetError != null) {
      return _errorResult(targetError);
    }
    return _mutationResult(
      source.parent!.directory!._renameAt(
        source.name,
        target.parent!.directory!,
        target.name,
      ),
    );
  }

  WasmComponentValueData _symlinkAt(
    int handle,
    String targetPath,
    String linkPath,
  ) {
    final descriptorError = _mutableDirectoryDescriptorError(handle);
    if (descriptorError != null) {
      return _errorResult(descriptorError);
    }
    if (!_isRelativeWasiPath(targetPath)) {
      return _errorResult('not-permitted');
    }
    final target = _resolveMutationParent(handle, linkPath);
    final error = target.error;
    if (error != null) {
      return _errorResult(error);
    }
    final parent = target.parent!;
    if (!parent.canMutate) {
      return _errorResult('read-only');
    }
    return _mutationResult(
      parent.directory!._symlinkAt(targetPath, target.name),
    );
  }

  WasmComponentValueData _readLinkAt(int handle, String path) {
    final target = _resolveMutationParent(handle, path);
    final error = target.error;
    if (error != null) {
      return _errorResult(error);
    }
    final result = target.parent!.directory!._readLinkAt(target.name);
    final readError = result.error;
    if (readError != null) {
      return _errorResult(readError.errorCode);
    }
    final linkTarget = result.target ?? '';
    return linkTarget.startsWith('/')
        ? _errorResult('not-permitted')
        : _ok(_stringData(linkTarget));
  }

  WasmComponentValueData _openAt(
    int handle,
    WasmComponentValueData pathFlags,
    String path,
    WasmComponentValueData openFlags,
    WasmComponentValueData flags,
  ) {
    final base = _descriptor(handle);
    if (base == null) {
      return _errorResult('bad-descriptor');
    }
    if (base.directory == null) {
      return _errorResult('not-directory');
    }
    if (openFlags.labels.contains('truncate') &&
        !flags.labels.contains('write')) {
      return _errorResult('invalid');
    }
    if ((_flagsContainMutation(flags) ||
            _openFlagsContainMutation(openFlags)) &&
        (!base.canMutate || !base.flags.contains('mutate-directory'))) {
      return _errorResult('read-only');
    }
    final resolved = _resolveAtResult(
      handle,
      path,
      followFinalSymlink: pathFlags.labels.contains('symlink-follow'),
    );
    final descriptor = resolved.descriptor;
    if (descriptor == null) {
      if (openFlags.labels.contains('create') &&
          !openFlags.labels.contains('directory') &&
          resolved.error == 'no-entry') {
        return _createFileAt(handle, path, flags);
      }
      return _errorResult(resolved.error ?? 'no-entry');
    }
    if (openFlags.labels.contains('create') &&
        openFlags.labels.contains('exclusive')) {
      return _errorResult('exist');
    }
    if (openFlags.labels.contains('directory') &&
        descriptor.kind != WASIPreview2FilesystemDescriptorKind.directory) {
      return _errorResult('not-directory');
    }
    if (_flagsContainMutation(flags) && !descriptor.canMutate) {
      return _errorResult('read-only');
    }
    if (flags.labels.contains('mutate-directory') &&
        descriptor.kind != WASIPreview2FilesystemDescriptorKind.directory) {
      return _errorResult('invalid');
    }
    if (flags.labels.contains('write') &&
        flags.labels.contains('file-integrity-sync') &&
        !descriptor.supportsSync) {
      return _errorResult('unsupported');
    }
    if (flags.labels.contains('write') &&
        flags.labels.contains('data-integrity-sync') &&
        !descriptor.supportsSyncData) {
      return _errorResult('unsupported');
    }
    final openedDescriptor = descriptor.withFlags(flags.labels);
    if (openFlags.labels.contains('truncate')) {
      if (!descriptor.canMutate) {
        return _errorResult('read-only');
      }
      final mutation = openedDescriptor.setSize(BigInt.zero);
      if (!mutation.isOk) {
        return _mutationResult(mutation);
      }
    }
    return _ok(_integerData(_insertDescriptor(openedDescriptor)));
  }

  WasmComponentValueData _createFileAt(
    int handle,
    String path,
    WasmComponentValueData flags,
  ) {
    final target = _resolveMutationParent(handle, path);
    final error = target.error;
    if (error != null) {
      return _errorResult(error);
    }
    final parent = target.parent!;
    if (!parent.canMutate) {
      return _errorResult('read-only');
    }
    final directory = parent.directory!;
    if (flags.labels.contains('mutate-directory')) {
      return _errorResult('invalid');
    }
    if (_flagsContainMutation(flags) && !directory.createdFileCanMutate) {
      return _errorResult('read-only');
    }
    if (flags.labels.contains('write') &&
        flags.labels.contains('file-integrity-sync') &&
        !directory.createdFileSupportsSync) {
      return _errorResult('unsupported');
    }
    if (flags.labels.contains('write') &&
        flags.labels.contains('data-integrity-sync') &&
        !directory.createdFileSupportsSyncData) {
      return _errorResult('unsupported');
    }
    final created = directory._createFileAt(target.name);
    if (!created.result.isOk) {
      return _mutationResult(created.result);
    }
    final guestPath = '${parent.guestPath}/${target.name}'.replaceAll(
      '//',
      '/',
    );
    final descriptor = _WASIPreview2FilesystemDescriptor.fromEntry(
      objectId: _objectIdForPath(guestPath),
      guestPath: guestPath,
      entry: created.entry!,
    );
    return _ok(
      _integerData(_insertDescriptor(descriptor.withFlags(flags.labels))),
    );
  }

  bool _isSameObject(int left, int right) {
    final leftDescriptor = _descriptor(left);
    final rightDescriptor = _descriptor(right);
    if (leftDescriptor == null || rightDescriptor == null) {
      return false;
    }
    final leftIdentity = leftDescriptor.metadata.objectIdentity;
    final rightIdentity = rightDescriptor.metadata.objectIdentity;
    if (leftIdentity != null && rightIdentity != null) {
      return leftIdentity == rightIdentity;
    }
    return leftDescriptor.objectId == rightDescriptor.objectId;
  }

  WasmComponentValueData _metadataHash(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_metadataHashData(descriptor));
  }

  WasmComponentValueData _metadataHashAt(
    int handle,
    WasmComponentValueData flags,
    String path,
  ) {
    final resolved = _resolveAtResult(
      handle,
      path,
      followFinalSymlink: flags.labels.contains('symlink-follow'),
    );
    final error = resolved.error;
    return error == null
        ? _ok(_metadataHashData(resolved.descriptor!))
        : _errorResult(error);
  }

  WasmComponentValueData _filesystemErrorCode(int errorHandle) {
    final debugString = streamsHost.errorHost.debugString(errorHandle);
    if (_filesystemErrorIndexes.containsKey(debugString)) {
      return _some(_enumData(debugString));
    }
    return _none();
  }

  ({_WASIPreview2FilesystemDescriptor? descriptor, String? error})
  _resolveAtResult(int handle, String path, {bool followFinalSymlink = false}) {
    final base = _descriptor(handle);
    if (base == null) {
      return (descriptor: null, error: 'bad-descriptor');
    }
    if (base.directory == null) {
      return (descriptor: null, error: 'not-directory');
    }
    if (!_isRelativeWasiPath(path)) {
      return (descriptor: null, error: 'not-permitted');
    }
    if (path.isEmpty || path == '.') {
      return (descriptor: base, error: null);
    }
    final segments = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    return _resolveSegments(
      base,
      segments,
      followFinalSymlink: followFinalSymlink,
      symlinkDepth: 0,
    );
  }

  ({_WASIPreview2FilesystemDescriptor? descriptor, String? error})
  _resolveSegments(
    _WASIPreview2FilesystemDescriptor base,
    List<String> segments, {
    required bool followFinalSymlink,
    required int symlinkDepth,
  }) {
    var depth = symlinkDepth;
    var pending = List<String>.of(segments);
    var index = 0;
    var current = base;
    final directories = <_WASIPreview2FilesystemDescriptor>[base];
    while (index < pending.length) {
      final segment = pending[index++];
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..') {
        if (directories.length == 1) {
          return (descriptor: null, error: 'not-permitted');
        }
        directories.removeLast();
        current = directories.last;
        continue;
      }
      final directory = current.directory;
      if (directory == null) {
        return (descriptor: null, error: 'not-directory');
      }
      final entry = directory._entryNamed(segment);
      if (entry == null) {
        return (descriptor: null, error: 'no-entry');
      }
      final guestPath = '${current.guestPath}/$segment'.replaceAll('//', '/');
      final next = _WASIPreview2FilesystemDescriptor.fromEntry(
        objectId: _objectIdForPath(guestPath),
        guestPath: guestPath,
        entry: entry,
      );
      final isFinal = index == pending.length;
      if (entry.kind == WASIPreview2FilesystemDescriptorKind.symbolicLink &&
          (!isFinal || followFinalSymlink)) {
        final target = entry._linkTarget;
        if (target == null || !_isRelativeWasiPath(target)) {
          return (descriptor: null, error: 'not-permitted');
        }
        depth++;
        if (depth > 40) {
          return (descriptor: null, error: 'loop');
        }
        final targetSegments = target
            .split('/')
            .where((part) => part.isNotEmpty)
            .toList();
        if (targetSegments.isEmpty) {
          return (descriptor: null, error: 'no-entry');
        }
        pending = <String>[...targetSegments, ...pending.skip(index)];
        index = 0;
        current = directories.last;
        continue;
      }
      if (!isFinal) {
        if (next.directory == null) {
          return (descriptor: null, error: 'not-directory');
        }
        directories.add(next);
        current = next;
        continue;
      }
      return (descriptor: next, error: null);
    }
    return (descriptor: current, error: null);
  }

  int _objectIdForPath(String path) {
    var hash = 0x811c9dc5;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? _nextObjectId++ : hash;
  }

  ({_WASIPreview2FilesystemDescriptor? parent, String name, String? error})
  _resolveExistingMutationTarget(
    int handle,
    String path, {
    required bool followFinalSymlink,
  }) {
    final base = _descriptor(handle);
    if (base == null) {
      return (parent: null, name: '', error: 'bad-descriptor');
    }
    final resolved = _resolveAtResult(
      handle,
      path,
      followFinalSymlink: followFinalSymlink,
    );
    final error = resolved.error;
    if (error != null) {
      return (parent: null, name: '', error: error);
    }
    final targetPath = resolved.descriptor!.guestPath;
    final basePath = base.guestPath;
    final prefix = basePath == '/' ? '/' : '$basePath/';
    if (targetPath == basePath) {
      return (parent: null, name: '', error: 'invalid');
    }
    if (!targetPath.startsWith(prefix)) {
      return (parent: null, name: '', error: 'not-permitted');
    }
    return _resolveMutationParent(handle, targetPath.substring(prefix.length));
  }

  ({_WASIPreview2FilesystemDescriptor? parent, String name, String? error})
  _resolveMutationParent(int handle, String path) {
    final base = _descriptor(handle);
    if (base == null) {
      return (parent: null, name: '', error: 'bad-descriptor');
    }
    if (base.directory == null) {
      return (parent: null, name: '', error: 'not-directory');
    }
    if (!_isRelativeWasiPath(path)) {
      return (parent: null, name: '', error: 'not-permitted');
    }
    final segments = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty || !_isSimplePathSegment(segments.last)) {
      return (parent: null, name: '', error: 'invalid');
    }
    if (segments.length == 1) {
      return (parent: base, name: segments.single, error: null);
    }
    final resolvedParent = _resolveAtResult(
      handle,
      segments.take(segments.length - 1).join('/'),
      followFinalSymlink: true,
    );
    final error = resolvedParent.error;
    if (error != null) {
      return (parent: null, name: '', error: error);
    }
    final parent = resolvedParent.descriptor!;
    if (parent.directory == null) {
      return (parent: null, name: '', error: 'not-directory');
    }
    return (parent: parent, name: segments.last, error: null);
  }
}

final class _WASIPreview2DirectoryEntryStream {
  _WASIPreview2DirectoryEntryStream(
    Iterable<WASIPreview2FilesystemDirectoryEntry> entries,
  ) : _entries = List<WASIPreview2FilesystemDirectoryEntry>.of(entries);

  final List<WASIPreview2FilesystemDirectoryEntry> _entries;
  int _offset = 0;

  WASIPreview2FilesystemDirectoryEntry? read() {
    if (_offset >= _entries.length) {
      return null;
    }
    return _entries[_offset++];
  }
}

final class _WASIPreview2FilesystemDescriptor {
  const _WASIPreview2FilesystemDescriptor._({
    required this.objectId,
    required this.guestPath,
    required this.kind,
    required this.size,
    required this.directory,
    required this.canMutate,
    required this.flags,
    required this.bytes,
    required this.entry,
  });

  factory _WASIPreview2FilesystemDescriptor.directory({
    required int objectId,
    required String guestPath,
    required WASIPreview2FilesystemDirectory directory,
  }) {
    return _WASIPreview2FilesystemDescriptor._(
      objectId: objectId,
      guestPath: guestPath,
      kind: WASIPreview2FilesystemDescriptorKind.directory,
      size: BigInt.zero,
      directory: directory,
      canMutate: directory.canMutate,
      flags: Set<String>.unmodifiable(<String>{
        'read',
        if (directory.canMutate) 'mutate-directory',
      }),
      bytes: Uint8List(0),
      entry: null,
    );
  }

  factory _WASIPreview2FilesystemDescriptor.fromEntry({
    required int objectId,
    required String guestPath,
    required WASIPreview2FilesystemDirectoryEntry entry,
  }) {
    return _WASIPreview2FilesystemDescriptor._(
      objectId: objectId,
      guestPath: guestPath,
      kind: entry.kind,
      size: entry.size,
      directory: entry.directory,
      canMutate: entry.canMutate,
      flags: Set<String>.unmodifiable(<String>{
        'read',
        if (entry.kind == WASIPreview2FilesystemDescriptorKind.regularFile &&
            entry.canMutate)
          'write',
        if (entry.kind == WASIPreview2FilesystemDescriptorKind.directory &&
            entry.canMutate)
          'mutate-directory',
      }),
      bytes: Uint8List(0),
      entry: entry,
    );
  }

  final int objectId;
  final String guestPath;
  final WASIPreview2FilesystemDescriptorKind kind;
  final BigInt size;
  final WASIPreview2FilesystemDirectory? directory;
  final bool canMutate;
  final Set<String> flags;
  final Uint8List bytes;
  final WASIPreview2FilesystemDirectoryEntry? entry;

  BigInt get currentSize => entry?._size ?? size;

  bool get supportsSyncData => entry?._supportsSyncData ?? false;

  bool get supportsSync => entry?._supportsSync ?? false;

  _WASIPreview2FilesystemDescriptor withFlags(Iterable<String> flags) {
    return _WASIPreview2FilesystemDescriptor._(
      objectId: objectId,
      guestPath: guestPath,
      kind: kind,
      size: size,
      directory: directory,
      canMutate: canMutate,
      flags: Set<String>.unmodifiable(flags),
      bytes: bytes,
      entry: entry,
    );
  }

  WASIPreview2FilesystemMetadata get metadata =>
      entry?._currentMetadata() ??
      directory?._currentMetadata() ??
      const WASIPreview2FilesystemMetadata();

  Uint8List bytesFrom(BigInt offset) {
    final entry = this.entry;
    if (entry != null) {
      return entry._bytesFrom(offset);
    }
    final start = offset > BigInt.from(bytes.length)
        ? bytes.length
        : offset.toInt();
    return bytes.sublist(start);
  }

  WASIPreview2FilesystemMutationResult writeAt(BigInt offset, Uint8List data) {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    final result = entry._writeAt(offset, data);
    return result.isOk ? _syncAfterWrite(entry) : result;
  }

  WASIPreview2FilesystemMutationResult setSize(BigInt nextSize) {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.readOnly,
      );
    }
    final result = entry._setSizeTo(nextSize);
    return result.isOk ? _syncAfterWrite(entry) : result;
  }

  WASIPreview2FilesystemMutationResult _syncAfterWrite(
    WASIPreview2FilesystemDirectoryEntry entry,
  ) {
    if (flags.contains('file-integrity-sync')) {
      return entry._syncTo();
    }
    if (flags.contains('data-integrity-sync')) {
      return entry._syncDataTo();
    }
    return const WASIPreview2FilesystemMutationResult.ok();
  }

  WASIPreview2FilesystemMutationResult setTimes(
    WASIPreview2FilesystemTimestampUpdate update,
  ) {
    final entry = this.entry;
    if (entry != null) {
      return entry._setTimesTo(update);
    }
    final directory = this.directory;
    if (directory != null) {
      return directory._setTimesTo(update);
    }
    return const WASIPreview2FilesystemMutationResult.error(
      WASIPreview2FilesystemMutationError.readOnly,
    );
  }

  WASIPreview2FilesystemMutationResult syncData() {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.unsupported,
      );
    }
    return entry._syncDataTo();
  }

  WASIPreview2FilesystemMutationResult sync() {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview2FilesystemMutationResult.error(
        WASIPreview2FilesystemMutationError.unsupported,
      );
    }
    return entry._syncTo();
  }
}

String _normalizePreopenPath(String path) {
  if (path.isEmpty) {
    return '/';
  }
  return path.startsWith('/') ? path : '/$path';
}

bool _isRelativeWasiPath(String path) =>
    !path.startsWith('/') && !path.contains('\u0000');

bool _isSimplePathSegment(String name) {
  return name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\\') &&
      !name.contains('\u0000');
}

int _handle(Object? value) {
  return switch (value) {
    int() => value,
    BigInt() => value.toInt(),
    _ => -1,
  };
}

BigInt _u64(Object? value) {
  return switch (value) {
    BigInt() => value,
    int() => BigInt.from(value),
    _ => BigInt.zero,
  };
}

({WASIPreview2FilesystemTimestampUpdate? update, String? error})
_timestampUpdate(Object? accessTimestamp, Object? modificationTimestamp) {
  final now =
      BigInt.from(DateTime.now().toUtc().microsecondsSinceEpoch) *
      BigInt.from(1000);
  final access = _timestampNanosFromUpdate(accessTimestamp, now);
  final accessError = access.error;
  if (accessError != null) {
    return (update: null, error: accessError);
  }
  final modification = _timestampNanosFromUpdate(modificationTimestamp, now);
  final modificationError = modification.error;
  if (modificationError != null) {
    return (update: null, error: modificationError);
  }
  return (
    update: WASIPreview2FilesystemTimestampUpdate(
      accessTimeNanos: access.nanos,
      modificationTimeNanos: modification.nanos,
    ),
    error: null,
  );
}

({BigInt? nanos, String? error}) _timestampNanosFromUpdate(
  Object? value,
  BigInt now,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.variant) {
    return (nanos: null, error: 'invalid');
  }
  final label = value.label;
  final index = value.index;
  if (label == 'no-change' || (label == null && index == 0)) {
    return (nanos: null, error: null);
  }
  if (label == 'now' || (label == null && index == 1)) {
    return (nanos: now, error: null);
  }
  if (label == 'timestamp' || (label == null && index == 2)) {
    final instant = value.associatedValue;
    if (instant == null) {
      return (nanos: null, error: 'invalid');
    }
    return _instantNanos(instant);
  }
  return (nanos: null, error: 'invalid');
}

({BigInt? nanos, String? error}) _instantNanos(WasmComponentValueData instant) {
  if (instant.kind != WasmComponentValueDataKind.record ||
      instant.items.length != 2) {
    return (nanos: null, error: 'invalid');
  }
  final seconds = _integerBigInt(instant.items[0].integer);
  final nanoseconds = _integerBigInt(instant.items[1].integer);
  if (seconds == null ||
      nanoseconds == null ||
      seconds < BigInt.zero ||
      nanoseconds < BigInt.zero ||
      nanoseconds >= BigInt.from(1000000000)) {
    return (nanos: null, error: 'invalid');
  }
  return (nanos: seconds * BigInt.from(1000000000) + nanoseconds, error: null);
}

BigInt? _integerBigInt(Object? integer) {
  return switch (integer) {
    BigInt() => integer,
    int() => BigInt.from(integer),
    _ => null,
  };
}

int _stableStringHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

bool _flagsContainMutation(WasmComponentValueData flags) {
  return flags.labels.contains('write') ||
      flags.labels.contains('mutate-directory');
}

const List<String> _descriptorFlagOrder = <String>[
  'read',
  'write',
  'file-integrity-sync',
  'data-integrity-sync',
  'requested-write-sync',
  'mutate-directory',
];

bool _openFlagsContainMutation(WasmComponentValueData flags) {
  return flags.labels.contains('create') || flags.labels.contains('truncate');
}

WasmComponentValueData _mutationResult(
  WASIPreview2FilesystemMutationResult result,
) {
  final error = result.error;
  return error == null ? _ok() : _errorResult(error.errorCode);
}

WasmComponentValueData _descriptorStatData(
  _WASIPreview2FilesystemDescriptor descriptor,
) {
  final metadata = descriptor.metadata;
  return _record(<WasmComponentValueData>[
    _descriptorTypeData(descriptor.kind),
    _integerData(metadata.linkCount ?? BigInt.one),
    _integerData(metadata.size ?? descriptor.currentSize),
    _optionalInstantData(metadata.accessTimeNanos),
    _optionalInstantData(metadata.modificationTimeNanos),
    _optionalInstantData(metadata.statusChangeTimeNanos),
  ]);
}

WasmComponentValueData _directoryEntryData(
  WASIPreview2FilesystemDirectoryEntry entry,
) {
  return _record(<WasmComponentValueData>[
    _descriptorTypeData(entry.kind),
    _stringData(entry.name),
  ]);
}

WasmComponentValueData _metadataHashData(
  _WASIPreview2FilesystemDescriptor descriptor,
) {
  var lower = BigInt.from(descriptor.objectId);
  lower = (lower << 32) ^ BigInt.from(descriptor.guestPath.length);
  lower ^= descriptor.currentSize;
  var upper = BigInt.from(descriptor.kind.index + 1);
  final directory = descriptor.directory;
  if (directory != null) {
    for (final entry in directory._currentEntries) {
      upper ^= BigInt.from(_stableStringHash(entry.name));
      upper = (upper << 5) ^ BigInt.from(entry.kind.index + 1);
      for (final byte in entry.bytes) {
        upper = ((upper << 5) ^ BigInt.from(byte)) & _u64Mask;
      }
    }
  } else {
    for (final byte in descriptor.bytesFrom(BigInt.zero)) {
      upper = ((upper << 5) ^ BigInt.from(byte)) & _u64Mask;
    }
  }
  return _record(<WasmComponentValueData>[
    _integerData(lower & _u64Mask),
    _integerData(upper & _u64Mask),
  ]);
}

WasmComponentValueData _descriptorTypeData(
  WASIPreview2FilesystemDescriptorKind kind,
) {
  return _enumData(switch (kind) {
    WASIPreview2FilesystemDescriptorKind.directory => 'directory',
    WASIPreview2FilesystemDescriptorKind.symbolicLink => 'symbolic-link',
    WASIPreview2FilesystemDescriptorKind.regularFile => 'regular-file',
    WASIPreview2FilesystemDescriptorKind.unknown => 'unknown',
  });
}

WasmComponentValueData _ok([WasmComponentValueData? associatedValue]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _errorResult(String code) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: _enumData(code),
  );
}

WasmComponentValueData _flagsData(List<String> labels) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.flags,
    rawBytes: Uint8List(0),
    labels: labels,
  );
}

WasmComponentValueData _list(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _tuple(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _record(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _enumData(String label) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.enumeration,
    rawBytes: Uint8List(0),
    index: _caseIndex(label),
    label: label,
  );
}

WasmComponentValueData _optionalInstantData(BigInt? nanos) {
  if (nanos == null || nanos < BigInt.zero) {
    return _none();
  }
  final seconds = nanos ~/ BigInt.from(1000000000);
  final nanoseconds = (nanos.remainder(BigInt.from(1000000000))).toInt();
  return _some(
    _record(<WasmComponentValueData>[
      _integerData(seconds),
      _integerData(nanoseconds),
    ]),
  );
}

WasmComponentValueData _some(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: value,
  );
}

WasmComponentValueData _none() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
}

WasmComponentValueData _stringData(String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.string,
    rawBytes: Uint8List(0),
    string: value,
  );
}

WasmComponentValueData _integerData(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

WasmComponentValueData _bool(bool value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.boolean,
    rawBytes: Uint8List(0),
    boolean: value,
  );
}

WasmComponentValueData _u8ListData(List<int> bytes) {
  return _list([for (final byte in bytes) _integerData(byte)]);
}

List<int> _u8List(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.list) {
    throw StateError('Expected list<u8>.');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.integer)
        _u8(item.integer)
      else
        throw StateError('Expected u8 list item.'),
  ];
}

int _u8(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= 0xff => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(0xff) =>
      value.toInt(),
    _ => throw StateError('Expected u8 value, got $value.'),
  };
}

int _boundedLength(BigInt value, int available) {
  if (value <= BigInt.zero || available <= 0) {
    return 0;
  }
  final max = BigInt.from(available);
  return (value < max ? value : max).toInt();
}

int _caseIndex(String label) {
  return _descriptorTypeIndexes[label] ?? _filesystemErrorIndexes[label] ?? 0;
}

const Map<String, int> _descriptorTypeIndexes = <String, int>{
  'unknown': 0,
  'block-device': 1,
  'character-device': 2,
  'directory': 3,
  'fifo': 4,
  'symbolic-link': 5,
  'regular-file': 6,
  'socket': 7,
};

const Map<String, int> _filesystemErrorIndexes = <String, int>{
  'access': 0,
  'would-block': 1,
  'already': 2,
  'bad-descriptor': 3,
  'busy': 4,
  'deadlock': 5,
  'quota': 6,
  'exist': 7,
  'file-too-large': 8,
  'illegal-byte-sequence': 9,
  'in-progress': 10,
  'interrupted': 11,
  'invalid': 12,
  'io': 13,
  'is-directory': 14,
  'loop': 15,
  'too-many-links': 16,
  'message-size': 17,
  'name-too-long': 18,
  'no-device': 19,
  'no-entry': 20,
  'no-lock': 21,
  'insufficient-memory': 22,
  'insufficient-space': 23,
  'not-directory': 24,
  'not-empty': 25,
  'not-recoverable': 26,
  'unsupported': 27,
  'no-tty': 28,
  'no-such-device': 29,
  'overflow': 30,
  'not-permitted': 31,
  'pipe': 32,
  'read-only': 33,
  'invalid-seek': 34,
  'text-file-busy': 35,
  'cross-device': 36,
};

final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;
