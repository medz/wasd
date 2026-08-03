import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/async_values.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';

/// Supplies the current entries for a filesystem directory.
typedef WASIPreview3FilesystemDirectoryEntriesProvider =
    Iterable<WASIPreview3FilesystemDirectoryEntry> Function();

/// Resolves one child entry by name without forcing a full directory scan.
typedef WASIPreview3FilesystemDirectoryEntryResolver =
    WASIPreview3FilesystemDirectoryEntry? Function(String name);

/// Reads regular-file bytes starting at a byte [offset].
typedef WASIPreview3FilesystemFileBytesProvider =
    Uint8List Function(BigInt offset);

/// Reads at most [maxBytes] regular-file bytes starting at [offset].
typedef WASIPreview3FilesystemFileChunkProvider =
    Uint8List Function(BigInt offset, int maxBytes);

/// Supplies the current byte length for a regular file.
typedef WASIPreview3FilesystemFileSizeProvider = BigInt Function();

/// Supplies current descriptor metadata for stat operations.
typedef WASIPreview3FilesystemMetadataProvider =
    WASIPreview3FilesystemMetadata Function();

/// Writes regular-file bytes starting at byte [offset].
typedef WASIPreview3FilesystemFileWriteCallback =
    WASIPreview3FilesystemMutationResult Function(
      BigInt offset,
      Uint8List bytes,
    );

/// Changes the byte length of a regular file.
typedef WASIPreview3FilesystemFileSetSizeCallback =
    WASIPreview3FilesystemMutationResult Function(BigInt size);

/// Applies advisory information to a regular-file region.
typedef WASIPreview3FilesystemFileAdviseCallback =
    WASIPreview3FilesystemMutationResult Function(
      BigInt offset,
      BigInt length,
      String advice,
    );

/// Flushes regular-file data or metadata to its backing store.
typedef WASIPreview3FilesystemFileSyncCallback =
    WASIPreview3FilesystemMutationResult Function();

/// Acquires host resources for one opened regular-file descriptor.
typedef WASIPreview3FilesystemFileOpenCallback =
    WASIPreview3FilesystemMutationResult Function(Set<String> flags);

/// Releases host resources owned by one regular-file descriptor.
typedef WASIPreview3FilesystemFileCloseCallback =
    void Function(Set<String> flags);

/// Updates access and modification timestamps for one filesystem object.
typedef WASIPreview3FilesystemSetTimesCallback =
    WASIPreview3FilesystemMutationResult Function(
      WASIPreview3FilesystemTimestampUpdate update,
    );

/// Mutates one child entry inside a directory.
typedef WASIPreview3FilesystemDirectoryMutationCallback =
    WASIPreview3FilesystemMutationResult Function(String name);

/// Creates and returns one regular-file entry inside a directory.
typedef WASIPreview3FilesystemDirectoryFileCreateCallback =
    WASIPreview3FilesystemDirectoryEntry? Function(String name);

/// Links one child from this directory into [targetDirectory].
typedef WASIPreview3FilesystemDirectoryLinkCallback =
    WASIPreview3FilesystemMutationResult Function(
      String oldName,
      WASIPreview3FilesystemDirectory targetDirectory,
      String newName,
    );

/// Renames one child from this directory into [targetDirectory].
typedef WASIPreview3FilesystemDirectoryRenameCallback =
    WASIPreview3FilesystemMutationResult Function(
      String oldName,
      WASIPreview3FilesystemDirectory targetDirectory,
      String newName,
    );

/// Creates a symbolic link entry.
typedef WASIPreview3FilesystemDirectorySymlinkCallback =
    WASIPreview3FilesystemMutationResult Function(
      String target,
      String linkName,
    );

/// Reads a symbolic link target for a child entry.
typedef WASIPreview3FilesystemDirectoryReadLinkCallback =
    WASIPreview3FilesystemReadLinkResult Function(String name);

/// Filesystem mutation failures that map directly to WASI 0.3 error-code
/// variants.
enum WASIPreview3FilesystemMutationError {
  /// Host permission denied.
  access('access'),

  /// Operation is already in progress or completed.
  already('already'),

  /// Descriptor is invalid or no longer owned.
  badDescriptor('bad-descriptor'),

  /// Resource is busy.
  busy('busy'),

  /// Operation would deadlock.
  deadlock('deadlock'),

  /// Storage quota was exceeded.
  quota('quota'),

  /// Target already exists.
  exist('exist'),

  /// File size exceeds a host or filesystem limit.
  fileTooLarge('file-too-large'),

  /// A path is not valid in the host filesystem encoding.
  illegalByteSequence('illegal-byte-sequence'),

  /// Operation remains in progress.
  inProgress('in-progress'),

  /// Operation was interrupted.
  interrupted('interrupted'),

  /// Invalid path, offset, or argument.
  invalid('invalid'),

  /// Host I/O failure.
  io('io'),

  /// A symbolic-link resolution cycle was detected.
  loop('loop'),

  /// Object has too many hard links.
  tooManyLinks('too-many-links'),

  /// Message or record is too large.
  messageSize('message-size'),

  /// Path name exceeds a host or filesystem limit.
  nameTooLong('name-too-long'),

  /// No suitable device is available.
  noDevice('no-device'),

  /// A directory was used where a regular file was required.
  isDirectory('is-directory'),

  /// Target path does not exist.
  noEntry('no-entry'),

  /// No lock is available.
  noLock('no-lock'),

  /// Host memory is insufficient.
  insufficientMemory('insufficient-memory'),

  /// A non-directory was used where a directory was required.
  notDirectory('not-directory'),

  /// Directory removal targeted a non-empty directory.
  notEmpty('not-empty'),

  /// Resource state cannot be recovered.
  notRecoverable('not-recoverable'),

  /// Path escaped the permitted preopen tree.
  notPermitted('not-permitted'),

  /// The host cannot represent the requested value.
  overflow('overflow'),

  /// Descriptor or backing store is read-only.
  readOnly('read-only'),

  /// The backing store has insufficient free space.
  insufficientSpace('insufficient-space'),

  /// The source and destination are on different filesystems.
  crossDevice('cross-device'),

  /// Operation is not supported by the host backing store.
  unsupported('unsupported'),

  /// Target is not a terminal.
  noTty('no-tty'),

  /// Referenced device does not exist.
  noSuchDevice('no-such-device'),

  /// Stream peer closed its pipe.
  pipe('pipe'),

  /// Seek target is invalid.
  invalidSeek('invalid-seek'),

  /// Executable text file is busy.
  textFileBusy('text-file-busy');

  const WASIPreview3FilesystemMutationError(this.errorCode);

  /// WIT `error-code` variant label.
  final String errorCode;
}

/// Result returned by Preview3 filesystem mutation callbacks.
final class WASIPreview3FilesystemMutationResult {
  /// Creates a successful mutation result.
  const WASIPreview3FilesystemMutationResult.ok()
    : error = null,
      isOther = false,
      otherMessage = null;

  /// Creates a failed mutation result with a WASI filesystem [error].
  const WASIPreview3FilesystemMutationResult.error(this.error)
    : isOther = false,
      otherMessage = null;

  /// Creates the WIT `other` failure with an optional diagnostic [message].
  const WASIPreview3FilesystemMutationResult.other([String? message])
    : error = null,
      isOther = true,
      otherMessage = message;

  /// WASI filesystem error reported by the mutation, or null on success.
  final WASIPreview3FilesystemMutationError? error;

  /// Whether this is the WIT `other` error case.
  final bool isOther;

  /// Optional WIT `other` diagnostic string.
  final String? otherMessage;

  /// Whether the mutation succeeded.
  bool get isOk => error == null && !isOther;
}

/// Timestamp update requested by WASI 0.3 filesystem operations.
final class WASIPreview3FilesystemTimestampUpdate {
  /// Creates a timestamp update.
  const WASIPreview3FilesystemTimestampUpdate({
    this.accessTimeNanos,
    this.modificationTimeNanos,
  });

  /// New access timestamp in nanoseconds since the Unix epoch, or null to keep
  /// the existing value.
  final BigInt? accessTimeNanos;

  /// New modification timestamp in nanoseconds since the Unix epoch, or null to
  /// keep the existing value.
  final BigInt? modificationTimeNanos;

  /// Whether either timestamp should change.
  bool get hasChanges =>
      accessTimeNanos != null || modificationTimeNanos != null;
}

/// Metadata returned by WASI 0.3 filesystem stat operations.
final class WASIPreview3FilesystemMetadata {
  /// Creates descriptor metadata.
  const WASIPreview3FilesystemMetadata({
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

/// Result returned by Preview3 filesystem readlink callbacks.
final class WASIPreview3FilesystemReadLinkResult {
  /// Creates a successful readlink result with [target].
  const WASIPreview3FilesystemReadLinkResult.ok(this.target) : error = null;

  /// Creates a failed readlink result with a WASI filesystem [error].
  const WASIPreview3FilesystemReadLinkResult.error(this.error) : target = null;

  /// Symbolic link target on success.
  final String? target;

  /// WASI filesystem error reported by the operation, or null on success.
  final WASIPreview3FilesystemMutationError? error;

  /// Whether the operation succeeded.
  bool get isOk => error == null;
}

/// WASI 0.3 filesystem object kind used by the Preview3 host.
enum WASIPreview3FilesystemDescriptorKind {
  /// Block-device descriptor.
  blockDevice,

  /// Character-device descriptor.
  characterDevice,

  /// Directory descriptor.
  directory,

  /// FIFO descriptor.
  fifo,

  /// Symbolic-link descriptor.
  symbolicLink,

  /// Regular-file descriptor.
  regularFile,

  /// Socket descriptor.
  socket,

  /// Host-specific descriptor kind.
  other,
}

/// Directory contents exposed through a WASI 0.3 filesystem preopen.
final class WASIPreview3FilesystemDirectory {
  /// Creates a directory model with stable [entries].
  WASIPreview3FilesystemDirectory({
    Iterable<WASIPreview3FilesystemDirectoryEntry> entries =
        const <WASIPreview3FilesystemDirectoryEntry>[],
    this.canMutate = false,
    this.mutationContext,
    WASIPreview3FilesystemMetadataProvider? metadata,
    WASIPreview3FilesystemDirectoryMutationCallback? createDirectory,
    WASIPreview3FilesystemDirectoryFileCreateCallback? createFile,
    WASIPreview3FilesystemDirectoryLinkCallback? link,
    WASIPreview3FilesystemDirectoryRenameCallback? rename,
    WASIPreview3FilesystemDirectorySymlinkCallback? symlink,
    WASIPreview3FilesystemDirectoryReadLinkCallback? readLink,
    WASIPreview3FilesystemSetTimesCallback? setTimes,
    WASIPreview3FilesystemDirectoryMutationCallback? removeDirectory,
    WASIPreview3FilesystemDirectoryMutationCallback? unlinkFile,
    bool? createdFileCanMutate,
    this.createdFileSupportsSync = true,
    this.createdFileSupportsSyncData = true,
  }) : _entries = List<WASIPreview3FilesystemDirectoryEntry>.of(entries),
       createdFileCanMutate = createdFileCanMutate ?? canMutate,
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
  WASIPreview3FilesystemDirectory.dynamic({
    required WASIPreview3FilesystemDirectoryEntriesProvider entries,
    WASIPreview3FilesystemDirectoryEntryResolver? resolveEntry,
    this.canMutate = false,
    this.mutationContext,
    WASIPreview3FilesystemMetadataProvider? metadata,
    WASIPreview3FilesystemDirectoryMutationCallback? createDirectory,
    WASIPreview3FilesystemDirectoryFileCreateCallback? createFile,
    WASIPreview3FilesystemDirectoryLinkCallback? link,
    WASIPreview3FilesystemDirectoryRenameCallback? rename,
    WASIPreview3FilesystemDirectorySymlinkCallback? symlink,
    WASIPreview3FilesystemDirectoryReadLinkCallback? readLink,
    WASIPreview3FilesystemSetTimesCallback? setTimes,
    WASIPreview3FilesystemDirectoryMutationCallback? removeDirectory,
    WASIPreview3FilesystemDirectoryMutationCallback? unlinkFile,
    bool? createdFileCanMutate,
    this.createdFileSupportsSync = false,
    this.createdFileSupportsSyncData = false,
  }) : _entries = <WASIPreview3FilesystemDirectoryEntry>[],
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
  List<WASIPreview3FilesystemDirectoryEntry> get entries =>
      List<WASIPreview3FilesystemDirectoryEntry>.unmodifiable(_currentEntries);

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

  final List<WASIPreview3FilesystemDirectoryEntry> _entries;
  final WASIPreview3FilesystemDirectoryEntriesProvider? _entriesProvider;
  final WASIPreview3FilesystemDirectoryEntryResolver? _entryResolver;
  final WASIPreview3FilesystemMetadataProvider? _metadata;
  final WASIPreview3FilesystemDirectoryMutationCallback? _createDirectory;
  final WASIPreview3FilesystemDirectoryFileCreateCallback? _createFile;
  final WASIPreview3FilesystemDirectoryLinkCallback? _link;
  final WASIPreview3FilesystemDirectoryRenameCallback? _rename;
  final WASIPreview3FilesystemDirectorySymlinkCallback? _symlink;
  final WASIPreview3FilesystemDirectoryReadLinkCallback? _readLink;
  final WASIPreview3FilesystemSetTimesCallback? _setTimes;
  final WASIPreview3FilesystemDirectoryMutationCallback? _removeDirectory;
  final WASIPreview3FilesystemDirectoryMutationCallback? _unlinkFile;

  Iterable<WASIPreview3FilesystemDirectoryEntry> get _currentEntries {
    final provider = _entriesProvider;
    if (provider == null) {
      return _entries;
    }
    return provider();
  }

  WASIPreview3FilesystemDirectoryEntry? _entryNamed(String name) {
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

  WASIPreview3FilesystemMutationResult _createDirectoryAt(String name) {
    if (!canMutate) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(name)) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    final callback = _createDirectory;
    if (callback != null) {
      return callback(name);
    }
    if (_entriesProvider != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (_entryNamed(name) != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.exist,
      );
    }
    _entries.add(
      WASIPreview3FilesystemDirectoryEntry.directory(
        name,
        directory: WASIPreview3FilesystemDirectory(canMutate: canMutate),
      ),
    );
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  ({
    WASIPreview3FilesystemDirectoryEntry? entry,
    WASIPreview3FilesystemMutationResult result,
  })
  _createFileAt(String name) {
    if (!canMutate) {
      return (
        entry: null,
        result: const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.readOnly,
        ),
      );
    }
    if (!_isSimplePathSegment(name)) {
      return (
        entry: null,
        result: const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.invalid,
        ),
      );
    }
    if (_entryNamed(name) != null) {
      return (
        entry: null,
        result: const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.exist,
        ),
      );
    }
    final callback = _createFile;
    if (callback != null) {
      final entry = callback(name);
      if (entry == null) {
        return (
          entry: null,
          result: const WASIPreview3FilesystemMutationResult.error(
            WASIPreview3FilesystemMutationError.io,
          ),
        );
      }
      return (
        entry: entry,
        result: const WASIPreview3FilesystemMutationResult.ok(),
      );
    }
    if (_entriesProvider != null) {
      return (
        entry: null,
        result: const WASIPreview3FilesystemMutationResult.error(
          WASIPreview3FilesystemMutationError.readOnly,
        ),
      );
    }
    final entry = WASIPreview3FilesystemDirectoryEntry.regularFile(
      name,
      canMutate: canMutate,
    );
    _entries.add(entry);
    return (
      entry: entry,
      result: const WASIPreview3FilesystemMutationResult.ok(),
    );
  }

  WASIPreview3FilesystemMutationResult _removeDirectoryAt(String name) {
    if (!canMutate) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(name)) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    final entry = _entryNamed(name);
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.noEntry,
      );
    }
    if (entry.kind != WASIPreview3FilesystemDescriptorKind.directory) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.notDirectory,
      );
    }
    if (entry.directory!._currentEntries.isNotEmpty) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.notEmpty,
      );
    }
    final callback = _removeDirectory;
    if (callback != null) {
      return callback(name);
    }
    if (_entriesProvider != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    _entries.removeWhere((candidate) => candidate.name == name);
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  WASIPreview3FilesystemMutationResult _setTimesTo(
    WASIPreview3FilesystemTimestampUpdate update,
  ) {
    if (!canMutate) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (!update.hasChanges) {
      return const WASIPreview3FilesystemMutationResult.ok();
    }
    final callback = _setTimes;
    if (callback != null) {
      return callback(update);
    }
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.readOnly,
    );
  }

  WASIPreview3FilesystemMetadata? _currentMetadata() => _metadata?.call();

  WASIPreview3FilesystemMutationResult _linkAt(
    String oldName,
    WASIPreview3FilesystemDirectory targetDirectory,
    String newName,
  ) {
    if (!targetDirectory.canMutate) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(oldName) || !_isSimplePathSegment(newName)) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    final callback = _link;
    if (callback != null) {
      return callback(oldName, targetDirectory, newName);
    }
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.readOnly,
    );
  }

  WASIPreview3FilesystemMutationResult _renameAt(
    String oldName,
    WASIPreview3FilesystemDirectory targetDirectory,
    String newName,
  ) {
    if (!canMutate || !targetDirectory.canMutate) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(oldName) || !_isSimplePathSegment(newName)) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    if (identical(this, targetDirectory) && oldName == newName) {
      return _entryNamed(oldName) == null
          ? const WASIPreview3FilesystemMutationResult.error(
              WASIPreview3FilesystemMutationError.noEntry,
            )
          : const WASIPreview3FilesystemMutationResult.ok();
    }
    final callback = _rename;
    if (callback != null) {
      return callback(oldName, targetDirectory, newName);
    }
    if (_entriesProvider != null || targetDirectory._entriesProvider != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    final entry = _entryNamed(oldName);
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.noEntry,
      );
    }
    if (targetDirectory._entryNamed(newName) != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.exist,
      );
    }
    _entries.removeWhere((candidate) => candidate.name == oldName);
    targetDirectory._entries.add(entry._renamed(newName));
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  WASIPreview3FilesystemMutationResult _symlinkAt(
    String target,
    String linkName,
  ) {
    if (!canMutate) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (target.contains('\u0000') || !_isSimplePathSegment(linkName)) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    final callback = _symlink;
    if (callback != null) {
      return callback(target, linkName);
    }
    if (_entriesProvider != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (_entryNamed(linkName) != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.exist,
      );
    }
    _entries.add(
      WASIPreview3FilesystemDirectoryEntry.symbolicLink(
        linkName,
        target: target,
      ),
    );
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  WASIPreview3FilesystemReadLinkResult _readLinkAt(String name) {
    if (!_isSimplePathSegment(name)) {
      return const WASIPreview3FilesystemReadLinkResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    final callback = _readLink;
    if (callback != null) {
      return callback(name);
    }
    final entry = _entryNamed(name);
    if (entry == null) {
      return const WASIPreview3FilesystemReadLinkResult.error(
        WASIPreview3FilesystemMutationError.noEntry,
      );
    }
    final target = entry._linkTarget;
    if (entry.kind != WASIPreview3FilesystemDescriptorKind.symbolicLink ||
        target == null) {
      return const WASIPreview3FilesystemReadLinkResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    return WASIPreview3FilesystemReadLinkResult.ok(target);
  }

  WASIPreview3FilesystemMutationResult _unlinkFileAt(String name) {
    if (!canMutate) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (!_isSimplePathSegment(name)) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    final entry = _entryNamed(name);
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.noEntry,
      );
    }
    if (entry.kind == WASIPreview3FilesystemDescriptorKind.directory) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.isDirectory,
      );
    }
    final callback = _unlinkFile;
    if (callback != null) {
      return callback(name);
    }
    if (_entriesProvider != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    _entries.removeWhere((candidate) => candidate.name == name);
    return const WASIPreview3FilesystemMutationResult.ok();
  }
}

/// One directory entry exposed by [WASIPreview3FilesystemDirectory].
final class WASIPreview3FilesystemDirectoryEntry {
  /// Creates a non-file, non-directory filesystem entry.
  WASIPreview3FilesystemDirectoryEntry.special(
    this.name, {
    required this.kind,
    BigInt? size,
    this.otherTypeName,
    WASIPreview3FilesystemMetadataProvider? metadata,
  }) : assert(
         kind != WASIPreview3FilesystemDescriptorKind.directory &&
             kind != WASIPreview3FilesystemDescriptorKind.symbolicLink &&
             kind != WASIPreview3FilesystemDescriptorKind.regularFile,
       ),
       size = size ?? BigInt.zero,
       directory = null,
       canMutate = false,
       _bytes = Uint8List(0),
       _readBytes = null,
       _readChunk = null,
       _currentSize = null,
       _metadata = metadata,
       _writeBytes = null,
       _setSize = null,
       _advise = null,
       _syncData = null,
       _sync = null,
       _setTimes = null,
       _openDescriptor = null,
       _closeDescriptor = null,
       _linkTarget = null;

  /// Creates a directory entry.
  WASIPreview3FilesystemDirectoryEntry.directory(
    this.name, {
    WASIPreview3FilesystemDirectory? directory,
    WASIPreview3FilesystemMetadataProvider? metadata,
    WASIPreview3FilesystemFileOpenCallback? openDescriptor,
    WASIPreview3FilesystemFileCloseCallback? closeDescriptor,
  }) : kind = WASIPreview3FilesystemDescriptorKind.directory,
       size = BigInt.zero,
       directory = directory ?? WASIPreview3FilesystemDirectory(),
       canMutate = directory?.canMutate ?? false,
       _bytes = Uint8List(0),
       _readBytes = null,
       _readChunk = null,
       _currentSize = null,
       _metadata = metadata,
       _writeBytes = null,
       _setSize = null,
       _advise = null,
       _syncData = null,
       _sync = null,
       _setTimes = null,
       _openDescriptor = openDescriptor,
       _closeDescriptor = closeDescriptor,
       otherTypeName = null,
       _linkTarget = null;

  /// Creates a symbolic-link entry.
  WASIPreview3FilesystemDirectoryEntry.symbolicLink(
    this.name, {
    required String target,
    WASIPreview3FilesystemMetadataProvider? metadata,
  }) : kind = WASIPreview3FilesystemDescriptorKind.symbolicLink,
       size = BigInt.from(utf8.encode(target).length),
       directory = null,
       canMutate = false,
       _bytes = Uint8List(0),
       _readBytes = null,
       _readChunk = null,
       _currentSize = null,
       _metadata = metadata,
       _writeBytes = null,
       _setSize = null,
       _advise = null,
       _syncData = null,
       _sync = null,
       _setTimes = null,
       _openDescriptor = null,
       _closeDescriptor = null,
       otherTypeName = null,
       _linkTarget = target;

  /// Creates a regular-file entry.
  WASIPreview3FilesystemDirectoryEntry.regularFile(
    this.name, {
    BigInt? size,
    List<int> bytes = const <int>[],
    this.canMutate = false,
    WASIPreview3FilesystemFileBytesProvider? readBytes,
    WASIPreview3FilesystemFileChunkProvider? readChunk,
    WASIPreview3FilesystemFileSizeProvider? currentSize,
    WASIPreview3FilesystemMetadataProvider? metadata,
    WASIPreview3FilesystemFileWriteCallback? writeBytes,
    WASIPreview3FilesystemFileSetSizeCallback? setSize,
    WASIPreview3FilesystemFileAdviseCallback? advise,
    WASIPreview3FilesystemFileSyncCallback? syncData,
    WASIPreview3FilesystemFileSyncCallback? sync,
    WASIPreview3FilesystemSetTimesCallback? setTimes,
    WASIPreview3FilesystemFileOpenCallback? openDescriptor,
    WASIPreview3FilesystemFileCloseCallback? closeDescriptor,
  }) : _bytes = Uint8List.fromList(bytes),
       _readBytes = readBytes,
       _readChunk = readChunk,
       _currentSize = currentSize,
       _metadata = metadata,
       _writeBytes = writeBytes,
       _setSize = setSize,
       _advise = advise,
       _syncData = syncData,
       _sync = sync,
       _setTimes = setTimes,
       _openDescriptor = openDescriptor,
       _closeDescriptor = closeDescriptor,
       otherTypeName = null,
       _linkTarget = null,
       kind = WASIPreview3FilesystemDescriptorKind.regularFile,
       size = size ?? currentSize?.call() ?? BigInt.from(bytes.length),
       directory = null;

  /// Entry name relative to the containing directory.
  final String name;

  /// Entry kind.
  final WASIPreview3FilesystemDescriptorKind kind;

  /// File size for regular files.
  final BigInt size;

  /// Nested directory contents for directory entries.
  final WASIPreview3FilesystemDirectory? directory;

  /// Whether this entry can be opened with mutation flags.
  final bool canMutate;

  /// Optional name carried by the WIT `descriptor-type.other` case.
  final String? otherTypeName;

  /// Immutable file contents for regular-file entries.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  Uint8List _bytes;
  final WASIPreview3FilesystemFileBytesProvider? _readBytes;
  final WASIPreview3FilesystemFileChunkProvider? _readChunk;
  final WASIPreview3FilesystemFileSizeProvider? _currentSize;
  final WASIPreview3FilesystemMetadataProvider? _metadata;
  final WASIPreview3FilesystemFileWriteCallback? _writeBytes;
  final WASIPreview3FilesystemFileSetSizeCallback? _setSize;
  final WASIPreview3FilesystemFileAdviseCallback? _advise;
  final WASIPreview3FilesystemFileSyncCallback? _syncData;
  final WASIPreview3FilesystemFileSyncCallback? _sync;
  final WASIPreview3FilesystemSetTimesCallback? _setTimes;
  final WASIPreview3FilesystemFileOpenCallback? _openDescriptor;
  final WASIPreview3FilesystemFileCloseCallback? _closeDescriptor;
  final String? _linkTarget;

  BigInt get _size {
    final currentSize = _currentSize?.call();
    if (currentSize != null) {
      return currentSize;
    }
    return kind == WASIPreview3FilesystemDescriptorKind.regularFile
        ? BigInt.from(_bytes.length)
        : size;
  }

  WASIPreview3FilesystemMetadata? _currentMetadata() {
    final metadata = _metadata?.call();
    if (metadata != null) {
      return metadata;
    }
    if (kind == WASIPreview3FilesystemDescriptorKind.directory) {
      return directory?._currentMetadata();
    }
    return null;
  }

  Uint8List _bytesFrom(BigInt offset, {int? maxBytes}) {
    if (offset < BigInt.zero) {
      return Uint8List(0);
    }
    final chunkReader = _readChunk;
    if (chunkReader != null && maxBytes != null) {
      return chunkReader(offset, maxBytes);
    }
    final reader = _readBytes;
    if (reader != null) {
      final bytes = reader(offset);
      return maxBytes != null && bytes.length > maxBytes
          ? Uint8List.sublistView(bytes, 0, maxBytes)
          : bytes;
    }
    final start = offset > BigInt.from(_bytes.length)
        ? _bytes.length
        : offset.toInt();
    final end = maxBytes == null || start + maxBytes > _bytes.length
        ? _bytes.length
        : start + maxBytes;
    return Uint8List.sublistView(_bytes, start, end);
  }

  WASIPreview3FilesystemMutationResult _writeAt(BigInt offset, Uint8List data) {
    if (kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.isDirectory,
      );
    }
    if (offset < BigInt.zero) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    if (offset > _maxHostCollectionLength) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.fileTooLarge,
      );
    }
    final callback = _writeBytes;
    if (callback != null) {
      return callback(offset, Uint8List.fromList(data));
    }
    if (!canMutate || _readBytes != null || _currentSize != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    final start = offset.toInt();
    final end = start + data.length;
    if (end > _maxHostCollectionLength.toInt()) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.fileTooLarge,
      );
    }
    if (end > _bytes.length) {
      final resized = Uint8List(end);
      resized.setAll(0, _bytes);
      _bytes = resized;
    }
    _bytes.setRange(start, end, data);
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  WASIPreview3FilesystemMutationResult _setSizeTo(BigInt nextSize) {
    if (kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.isDirectory,
      );
    }
    if (nextSize < BigInt.zero) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    if (nextSize > _maxHostCollectionLength) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.fileTooLarge,
      );
    }
    final callback = _setSize;
    if (callback != null) {
      return callback(nextSize);
    }
    if (!canMutate || _readBytes != null || _currentSize != null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    final length = nextSize.toInt();
    final resized = Uint8List(length);
    final preserved = length < _bytes.length ? length : _bytes.length;
    resized.setRange(0, preserved, _bytes);
    _bytes = resized;
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  WASIPreview3FilesystemMutationResult _setTimesTo(
    WASIPreview3FilesystemTimestampUpdate update,
  ) {
    if (!canMutate) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    if (!update.hasChanges) {
      return const WASIPreview3FilesystemMutationResult.ok();
    }
    if (kind == WASIPreview3FilesystemDescriptorKind.directory) {
      return directory!._setTimesTo(update);
    }
    if (kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.unsupported,
      );
    }
    final callback = _setTimes;
    if (callback != null) {
      return callback(update);
    }
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.readOnly,
    );
  }

  WASIPreview3FilesystemMutationResult _adviseTo(
    BigInt offset,
    BigInt length,
    String advice,
  ) {
    if (kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.unsupported,
      );
    }
    final callback = _advise;
    if (callback != null) {
      return callback(offset, length, advice);
    }
    if (_readBytes == null && _readChunk == null && _currentSize == null) {
      return const WASIPreview3FilesystemMutationResult.ok();
    }
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.unsupported,
    );
  }

  WASIPreview3FilesystemMutationResult _syncDataTo() {
    if (kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.unsupported,
      );
    }
    final callback = _syncData;
    if (callback != null) {
      return callback();
    }
    if (_readBytes == null && _readChunk == null && _currentSize == null) {
      return const WASIPreview3FilesystemMutationResult.ok();
    }
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.unsupported,
    );
  }

  bool get _supportsSyncData =>
      kind == WASIPreview3FilesystemDescriptorKind.regularFile &&
      (_syncData != null ||
          _readBytes == null && _readChunk == null && _currentSize == null);

  WASIPreview3FilesystemMutationResult _syncTo() {
    if (kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.unsupported,
      );
    }
    final callback = _sync;
    if (callback != null) {
      return callback();
    }
    if (_readBytes == null && _readChunk == null && _currentSize == null) {
      return const WASIPreview3FilesystemMutationResult.ok();
    }
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.unsupported,
    );
  }

  bool get _supportsSync =>
      kind == WASIPreview3FilesystemDescriptorKind.regularFile &&
      (_sync != null ||
          _readBytes == null && _readChunk == null && _currentSize == null);

  WASIPreview3FilesystemMutationResult _openWithFlags(Set<String> flags) =>
      _openDescriptor?.call(flags) ??
      const WASIPreview3FilesystemMutationResult.ok();

  void _closeWithFlags(Set<String> flags) => _closeDescriptor?.call(flags);

  WASIPreview3FilesystemDirectoryEntry _renamed(String name) {
    return switch (kind) {
      WASIPreview3FilesystemDescriptorKind.directory =>
        WASIPreview3FilesystemDirectoryEntry.directory(
          name,
          directory: directory,
          metadata: _metadata,
          openDescriptor: _openDescriptor,
          closeDescriptor: _closeDescriptor,
        ),
      WASIPreview3FilesystemDescriptorKind.symbolicLink =>
        WASIPreview3FilesystemDirectoryEntry.symbolicLink(
          name,
          target: _linkTarget ?? '',
          metadata: _metadata,
        ),
      WASIPreview3FilesystemDescriptorKind.regularFile =>
        WASIPreview3FilesystemDirectoryEntry.regularFile(
          name,
          size: size,
          bytes: _bytes,
          canMutate: canMutate,
          readBytes: _readBytes,
          readChunk: _readChunk,
          currentSize: _currentSize,
          metadata: _metadata,
          writeBytes: _writeBytes,
          setSize: _setSize,
          advise: _advise,
          syncData: _syncData,
          sync: _sync,
          setTimes: _setTimes,
          openDescriptor: _openDescriptor,
          closeDescriptor: _closeDescriptor,
        ),
      _ => WASIPreview3FilesystemDirectoryEntry.special(
        name,
        kind: kind,
        size: size,
        otherTypeName: otherTypeName,
        metadata: _metadata,
      ),
    };
  }
}

/// WASI 0.3 `wasi:filesystem` host imports.
base class WASIPreview3FilesystemHost {
  /// Creates a filesystem host with preopened guest directories.
  WASIPreview3FilesystemHost({
    Map<String, WASIPreview3FilesystemDirectory> preopens =
        const <String, WASIPreview3FilesystemDirectory>{},
    WASIComponentResourceTable? table,
  }) : table = table ?? WASIComponentResourceTable() {
    for (final entry in preopens.entries) {
      final guestPath = _normalizePreopenPath(entry.key);
      final descriptor = _WASIPreview3FilesystemDescriptor.directory(
        objectId: _nextObjectId++,
        guestPath: guestPath,
        directory: entry.value,
      );
      _preopens.add((descriptor, guestPath));
    }
  }

  /// Component resource table that owns descriptor handles.
  final WASIComponentResourceTable table;

  late final WASIComponentResourceType<_WASIPreview3FilesystemDescriptor>
  _descriptorType = table.defineType<_WASIPreview3FilesystemDescriptor>(
    'wasi:filesystem/types@0.3.0.descriptor',
    onDrop: (descriptor) => descriptor.close(),
  );

  int _nextObjectId = 1;
  final _preopens = <(_WASIPreview3FilesystemDescriptor, String)>[];
  final _appendTails = <Object, Future<void>>{};

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:filesystem/preopens@0.3.0.get-directories': (_) =>
            _getDirectories(),
        'wasi:filesystem/types@0.3.0.descriptor.read-via-stream': (args) =>
            _readViaStream(_handle(args[0]), _u64(args[1])),
        'wasi:filesystem/types@0.3.0.descriptor.write-via-stream': (args) =>
            _writeViaStream(_handle(args[0]), args[1], _u64(args[2])),
        'wasi:filesystem/types@0.3.0.descriptor.append-via-stream': (args) =>
            _appendViaStream(_handle(args[0]), args[1]),
        'wasi:filesystem/types@0.3.0.descriptor.advise': (args) => _advise(
          _handle(args[0]),
          _u64(args[1]),
          _u64(args[2]),
          args[3] as WasmComponentValueData,
        ),
        'wasi:filesystem/types@0.3.0.descriptor.sync-data': (args) =>
            _syncData(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.get-flags': (args) =>
            _getFlags(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.get-type': (args) =>
            _getType(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.set-size': (args) =>
            _setSize(_handle(args[0]), _u64(args[1])),
        'wasi:filesystem/types@0.3.0.descriptor.set-times': (args) =>
            _setTimes(_handle(args[0]), args[1], args[2]),
        'wasi:filesystem/types@0.3.0.descriptor.read-directory': (args) =>
            _readDirectory(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.sync': (args) =>
            _sync(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.create-directory-at': (args) =>
            _createDirectoryAt(_handle(args[0]), args[1] as String),
        'wasi:filesystem/types@0.3.0.descriptor.stat': (args) =>
            _stat(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.stat-at': (args) => _statAt(
          _handle(args[0]),
          args[1] as WasmComponentValueData,
          args[2] as String,
        ),
        'wasi:filesystem/types@0.3.0.descriptor.set-times-at': (args) =>
            _setTimesAt(
              _handle(args[0]),
              args[1] as WasmComponentValueData,
              args[2] as String,
              args[3],
              args[4],
            ),
        'wasi:filesystem/types@0.3.0.descriptor.link-at': (args) => _linkAt(
          _handle(args[0]),
          args[1] as WasmComponentValueData,
          args[2] as String,
          _handle(args[3]),
          args[4] as String,
        ),
        'wasi:filesystem/types@0.3.0.descriptor.open-at': (args) => _openAt(
          _handle(args[0]),
          args[1] as WasmComponentValueData,
          args[2] as String,
          args[3] as WasmComponentValueData,
          args[4] as WasmComponentValueData,
        ),
        'wasi:filesystem/types@0.3.0.descriptor.readlink-at': (args) =>
            _readLinkAt(_handle(args[0]), args[1] as String),
        'wasi:filesystem/types@0.3.0.descriptor.remove-directory-at': (args) =>
            _removeDirectoryAt(_handle(args[0]), args[1] as String),
        'wasi:filesystem/types@0.3.0.descriptor.rename-at': (args) => _renameAt(
          _handle(args[0]),
          args[1] as String,
          _handle(args[2]),
          args[3] as String,
        ),
        'wasi:filesystem/types@0.3.0.descriptor.symlink-at': (args) =>
            _symlinkAt(_handle(args[0]), args[1] as String, args[2] as String),
        'wasi:filesystem/types@0.3.0.descriptor.unlink-file-at': (args) =>
            _unlinkFileAt(_handle(args[0]), args[1] as String),
        'wasi:filesystem/types@0.3.0.descriptor.is-same-object': (args) =>
            _isSameObject(_handle(args[0]), _handle(args[1])),
        'wasi:filesystem/types@0.3.0.descriptor.metadata-hash': (args) =>
            _metadataHash(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.metadata-hash-at': (args) =>
            _metadataHashAt(
              _handle(args[0]),
              args[1] as WasmComponentValueData,
              args[2] as String,
            ),
      });

  int _insertDescriptor(_WASIPreview3FilesystemDescriptor descriptor) {
    return table.insert<_WASIPreview3FilesystemDescriptor>(
      _descriptorType,
      descriptor,
    );
  }

  WasmComponentValueData _openDescriptor(
    _WASIPreview3FilesystemDescriptor descriptor,
  ) {
    final opened = descriptor.open();
    if (!opened.isOk) return _mutationResult(opened);
    try {
      return _ok(_integerData(_insertDescriptor(descriptor)));
    } catch (_) {
      descriptor.close();
      rethrow;
    }
  }

  _WASIPreview3FilesystemDescriptor? _descriptor(int handle) {
    try {
      return table.get<_WASIPreview3FilesystemDescriptor>(
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

  List<Object?> _readViaStream(int handle, BigInt offset) {
    final stream = WASIComponentStream<int>(
      'filesystem-read-$handle',
      maxBufferedElements: _fileStreamBufferSize,
    );
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-read-result-$handle',
    );
    if (offset < BigInt.zero) {
      stream.writable.close();
      result.writable.complete(_errorResult('invalid'));
      return <Object?>[stream, result];
    }
    final descriptor = _descriptor(handle);
    final error = _readableDescriptorError(descriptor);
    if (error != null) {
      stream.writable.close();
      result.writable.complete(_errorResult(error));
      return <Object?>[stream, result];
    }
    unawaited(
      table.borrowAsync<_WASIPreview3FilesystemDescriptor, void>(
        _descriptorType,
        handle,
        (descriptor) => _produceFileRead(descriptor, offset, stream, result),
      ),
    );
    return <Object?>[stream, result];
  }

  Future<void> _produceFileRead(
    _WASIPreview3FilesystemDescriptor descriptor,
    BigInt initialOffset,
    WASIComponentStream<int> stream,
    WASIComponentFuture<WasmComponentValueData> result,
  ) async {
    var offset = initialOffset;
    try {
      while (offset < descriptor.currentSize) {
        final bytes = descriptor.bytesFrom(
          offset,
          maxBytes: _fileStreamChunkSize,
        );
        if (bytes.isEmpty) {
          break;
        }
        var written = 0;
        while (written < bytes.length) {
          final count = await stream.writable.writeWhenAvailable(
            bytes.sublist(written),
          );
          if (count <= 0) {
            throw StateError('filesystem read stream made no progress');
          }
          written += count;
        }
        offset += BigInt.from(bytes.length);
      }
      if (!stream.writable.isClosed) {
        stream.writable.close();
      }
      _completeWriteResult(result, _unitOk());
    } catch (_) {
      if (!stream.writable.isClosed) {
        stream.writable.close();
      }
      _completeWriteResult(
        result,
        stream.readable.isDropped || stream.readable.isCancelled
            ? _unitOk()
            : _errorResult('io'),
      );
    }
  }

  WASIComponentFuture<WasmComponentValueData> _writeViaStream(
    int handle,
    Object? streamValue,
    BigInt offset,
  ) {
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-write-result-$handle',
    );
    final stream = _streamArgument(streamValue);
    if (stream == null) {
      result.writable.complete(_errorResult('invalid'));
      return result;
    }
    if (offset < BigInt.zero) {
      result.writable.complete(_errorResult('invalid'));
      return result;
    }
    final descriptor = _descriptor(handle);
    final error = _writableDescriptorError(descriptor);
    if (error != null) {
      result.writable.complete(_errorResult(error));
      return result;
    }
    unawaited(
      table.borrowAsync<_WASIPreview3FilesystemDescriptor, void>(
        _descriptorType,
        handle,
        (descriptor) => _drainWriteStream(descriptor, stream, offset, result),
      ),
    );
    return result;
  }

  WASIComponentFuture<WasmComponentValueData> _appendViaStream(
    int handle,
    Object? streamValue,
  ) {
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-append-result-$handle',
    );
    final stream = _streamArgument(streamValue);
    if (stream == null) {
      result.writable.complete(_errorResult('invalid'));
      return result;
    }
    final descriptor = _descriptor(handle);
    final error = _writableDescriptorError(descriptor);
    if (error != null) {
      result.writable.complete(_errorResult(error));
      return result;
    }
    unawaited(
      table.borrowAsync<_WASIPreview3FilesystemDescriptor, void>(
        _descriptorType,
        handle,
        (descriptor) => _drainAppendStream(descriptor, stream, result),
      ),
    );
    return result;
  }

  Future<void> _drainAppendStream(
    _WASIPreview3FilesystemDescriptor descriptor,
    WASIComponentStream<int> stream,
    WASIComponentFuture<WasmComponentValueData> result,
  ) async {
    final key = descriptor.appendSerializationKey;
    final previous = _appendTails[key];
    final release = Completer<void>();
    final tail = release.future;
    _appendTails[key] = tail;
    try {
      if (previous != null) {
        await previous;
      }
      await _drainWriteStream(
        descriptor,
        stream,
        descriptor.currentSize,
        result,
      );
    } finally {
      release.complete();
      if (identical(_appendTails[key], tail)) {
        _appendTails.remove(key);
      }
    }
  }

  Future<void> _drainWriteStream(
    _WASIPreview3FilesystemDescriptor descriptor,
    WASIComponentStream<int> stream,
    BigInt initialOffset,
    WASIComponentFuture<WasmComponentValueData> result,
  ) async {
    var offset = initialOffset;
    try {
      while (true) {
        final chunk = await stream.readable.readWhenAvailable(8192);
        if (chunk.isEmpty) {
          break;
        }
        final mutation = descriptor.writeAt(offset, Uint8List.fromList(chunk));
        if (!mutation.isOk) {
          if (!stream.readable.isDropped && !stream.readable.isCancelled) {
            stream.readable.cancel();
          }
          _completeWriteResult(result, _mutationResult(mutation));
          return;
        }
        offset += BigInt.from(chunk.length);
      }
      _completeWriteResult(result, _unitOk());
    } on WASIComponentAsyncEndpointStateError catch (error) {
      _completeWriteResult(
        result,
        error.failure == WASIComponentAsyncEndpointFailure.dropped
            ? _unitOk()
            : _errorResult('io'),
      );
    } catch (_) {
      _completeWriteResult(result, _errorResult('io'));
    }
  }

  void _completeWriteResult(
    WASIComponentFuture<WasmComponentValueData> result,
    WasmComponentValueData value,
  ) {
    if (result.writable.canComplete) {
      result.writable.complete(value);
    }
  }

  WASIComponentStream<int>? _streamArgument(Object? value) {
    if (value is WASIComponentStream<int>) {
      return value;
    }
    return null;
  }

  String? _readableDescriptorError(
    _WASIPreview3FilesystemDescriptor? descriptor,
  ) {
    if (descriptor == null) {
      return 'bad-descriptor';
    }
    if (descriptor.kind == WASIPreview3FilesystemDescriptorKind.directory) {
      return 'is-directory';
    }
    if (descriptor.kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return 'invalid';
    }
    if (!descriptor.flags.contains('read')) {
      return 'not-permitted';
    }
    return null;
  }

  String? _writableDescriptorError(
    _WASIPreview3FilesystemDescriptor? descriptor,
  ) {
    if (descriptor == null) {
      return 'bad-descriptor';
    }
    if (descriptor.kind == WASIPreview3FilesystemDescriptorKind.directory) {
      return 'is-directory';
    }
    if (descriptor.kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return 'invalid';
    }
    if (!descriptor.canMutate) {
      return 'read-only';
    }
    if (!descriptor.flags.contains('write')) {
      return 'access';
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

  WasmComponentValueData _advise(
    int handle,
    BigInt offset,
    BigInt length,
    WasmComponentValueData advice,
  ) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    if (descriptor.kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return _errorResult('bad-descriptor');
    }
    final label = advice.label;
    if (label == null || !_adviceLabels.contains(label)) {
      return _errorResult('invalid');
    }
    return _mutationResult(descriptor.advise(offset, length, label));
  }

  WasmComponentValueData _syncData(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    if (descriptor.kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return _errorResult('unsupported');
    }
    if (!descriptor.flags.contains('write')) {
      return _unitOk();
    }
    return _mutationResult(descriptor.syncData());
  }

  WasmComponentValueData _sync(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    if (descriptor.kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      return _errorResult('unsupported');
    }
    if (!descriptor.flags.contains('write')) {
      return _unitOk();
    }
    return _mutationResult(descriptor.sync());
  }

  WasmComponentValueData _getFlags(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(
      _flagsData(<String>[
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
        descriptor.kind == WASIPreview3FilesystemDescriptorKind.directory
        ? descriptor.flags.contains('mutate-directory')
        : descriptor.flags.contains('write');
    if (!descriptor.canMutate) {
      return _errorResult('read-only');
    }
    if (!mutationAllowed) {
      return _errorResult('access');
    }
    return _mutationResult(descriptor.setTimes(update.update!));
  }

  WasmComponentValueData _getType(int handle) {
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(
      _descriptorTypeData(
        descriptor.kind,
        otherTypeName: descriptor.otherTypeName,
      ),
    );
  }

  List<Object?> _readDirectory(int handle) {
    final stream = WASIComponentStream<WasmComponentValueData>(
      'filesystem-directory-$handle',
      maxBufferedElements: _directoryStreamBufferSize,
    );
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-directory-result-$handle',
    );
    final descriptor = _descriptor(handle);
    if (descriptor == null) {
      stream.writable.close();
      result.writable.complete(_errorResult('bad-descriptor'));
      return <Object?>[stream, result];
    }
    if (descriptor.directory == null) {
      stream.writable.close();
      result.writable.complete(_errorResult('not-directory'));
      return <Object?>[stream, result];
    }
    if (!descriptor.flags.contains('read')) {
      stream.writable.close();
      result.writable.complete(_errorResult('not-permitted'));
      return <Object?>[stream, result];
    }
    final entries = descriptor.directory!._currentEntries.iterator;
    var exhausted = false;
    while (stream.writable.canWriteImmediately(1)) {
      if (!entries.moveNext()) {
        exhausted = true;
        break;
      }
      stream.writable.write(_directoryEntryData(entries.current));
    }
    if (exhausted) {
      stream.writable.close();
      result.writable.complete(_unitOk());
    } else {
      unawaited(
        table.borrowAsync<_WASIPreview3FilesystemDescriptor, void>(
          _descriptorType,
          handle,
          (_) => _produceDirectoryRead(entries, stream, result),
        ),
      );
    }
    return <Object?>[stream, result];
  }

  Future<void> _produceDirectoryRead(
    Iterator<WASIPreview3FilesystemDirectoryEntry> entries,
    WASIComponentStream<WasmComponentValueData> stream,
    WASIComponentFuture<WasmComponentValueData> result,
  ) async {
    try {
      while (entries.moveNext()) {
        final count = await stream.writable.writeWhenAvailable(
          <WasmComponentValueData>[_directoryEntryData(entries.current)],
        );
        if (count != 1) {
          throw StateError('filesystem directory stream made no progress');
        }
      }
      if (!stream.writable.isClosed) {
        stream.writable.close();
      }
      _completeWriteResult(result, _unitOk());
    } catch (_) {
      if (!stream.writable.isClosed) {
        stream.writable.close();
      }
      _completeWriteResult(
        result,
        stream.readable.isDropped || stream.readable.isCancelled
            ? _unitOk()
            : _errorResult('io'),
      );
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
    if (path == '.') {
      return _errorResult('exist');
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
    if (path.endsWith('/')) {
      final resolved = _resolveAtResult(handle, path, followFinalSymlink: true);
      final error = resolved.error;
      if (error != null) {
        return _errorResult(error);
      }
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
    if (path == '.' || path == '..') {
      return _errorResult('is-directory');
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
    final effectiveFlags = _effectiveDescriptorFlags(
      openFlags.labels,
      flags.labels,
    );
    if (openFlags.labels.contains('truncate') &&
        !effectiveFlags.contains('write')) {
      return _errorResult('invalid');
    }
    if ((_flagsContainMutation(effectiveFlags) ||
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
        return _createFileAt(handle, path, effectiveFlags);
      }
      return _errorResult(resolved.error ?? 'no-entry');
    }
    if (openFlags.labels.contains('create') &&
        openFlags.labels.contains('exclusive')) {
      return _errorResult('exist');
    }
    if (openFlags.labels.contains('directory') &&
        descriptor.kind != WASIPreview3FilesystemDescriptorKind.directory) {
      return _errorResult('not-directory');
    }
    if (_flagsContainMutation(effectiveFlags) && !descriptor.canMutate) {
      return _errorResult('read-only');
    }
    if (effectiveFlags.contains('mutate-directory') &&
        descriptor.kind != WASIPreview3FilesystemDescriptorKind.directory) {
      return _errorResult('invalid');
    }
    if (effectiveFlags.contains('write') &&
        effectiveFlags.contains('file-integrity-sync') &&
        !descriptor.supportsSync) {
      return _errorResult('unsupported');
    }
    if (effectiveFlags.contains('write') &&
        effectiveFlags.contains('data-integrity-sync') &&
        !descriptor.supportsSyncData) {
      return _errorResult('unsupported');
    }
    final openedDescriptor = descriptor.withFlags(effectiveFlags);
    final opened = openedDescriptor.open();
    if (!opened.isOk) return _mutationResult(opened);
    if (openFlags.labels.contains('truncate')) {
      if (!descriptor.canMutate) {
        openedDescriptor.close();
        return _errorResult('read-only');
      }
      final mutation = openedDescriptor.setSize(BigInt.zero);
      if (!mutation.isOk) {
        openedDescriptor.close();
        return _mutationResult(mutation);
      }
    }
    try {
      return _ok(_integerData(_insertDescriptor(openedDescriptor)));
    } catch (_) {
      openedDescriptor.close();
      rethrow;
    }
  }

  WasmComponentValueData _createFileAt(
    int handle,
    String path,
    Set<String> flags,
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
    if (flags.contains('mutate-directory')) {
      return _errorResult('invalid');
    }
    if (_flagsContainMutation(flags) && !directory.createdFileCanMutate) {
      return _errorResult('read-only');
    }
    if (flags.contains('write') &&
        flags.contains('file-integrity-sync') &&
        !directory.createdFileSupportsSync) {
      return _errorResult('unsupported');
    }
    if (flags.contains('write') &&
        flags.contains('data-integrity-sync') &&
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
    final descriptor = _WASIPreview3FilesystemDescriptor.fromEntry(
      objectId: _objectIdForPath(guestPath),
      guestPath: guestPath,
      entry: created.entry!,
    );
    return _openDescriptor(descriptor.withFlags(flags));
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

  ({_WASIPreview3FilesystemDescriptor? descriptor, String? error})
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
    if (path.isEmpty) {
      return (descriptor: null, error: 'no-entry');
    }
    if (path == '.') {
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

  ({_WASIPreview3FilesystemDescriptor? descriptor, String? error})
  _resolveSegments(
    _WASIPreview3FilesystemDescriptor base,
    List<String> segments, {
    required bool followFinalSymlink,
    required int symlinkDepth,
  }) {
    var depth = symlinkDepth;
    var pending = List<String>.of(segments);
    var index = 0;
    var current = base;
    final directories = <_WASIPreview3FilesystemDescriptor>[base];
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
      final next = _WASIPreview3FilesystemDescriptor.fromEntry(
        objectId: _objectIdForPath(guestPath),
        guestPath: guestPath,
        entry: entry,
      );
      final isFinal = index == pending.length;
      if (entry.kind == WASIPreview3FilesystemDescriptorKind.symbolicLink &&
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

  ({_WASIPreview3FilesystemDescriptor? parent, String name, String? error})
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
      return (parent: null, name: '', error: 'not-permitted');
    }
    if (!targetPath.startsWith(prefix)) {
      return (parent: null, name: '', error: 'not-permitted');
    }
    return _resolveMutationParent(handle, targetPath.substring(prefix.length));
  }

  ({_WASIPreview3FilesystemDescriptor? parent, String name, String? error})
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
    if (path.isEmpty) {
      return (parent: null, name: '', error: 'no-entry');
    }
    final segments = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.last == '..') {
      return (parent: null, name: '', error: 'not-permitted');
    }
    if (!_isSimplePathSegment(segments.last)) {
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

final class _WASIPreview3FilesystemDescriptor {
  const _WASIPreview3FilesystemDescriptor._({
    required this.objectId,
    required this.guestPath,
    required this.kind,
    required this.size,
    required this.directory,
    required this.canMutate,
    required this.flags,
    required this.bytes,
    required this.otherTypeName,
    required this.entry,
  });

  factory _WASIPreview3FilesystemDescriptor.directory({
    required int objectId,
    required String guestPath,
    required WASIPreview3FilesystemDirectory directory,
  }) {
    return _WASIPreview3FilesystemDescriptor._(
      objectId: objectId,
      guestPath: guestPath,
      kind: WASIPreview3FilesystemDescriptorKind.directory,
      size: BigInt.zero,
      directory: directory,
      canMutate: directory.canMutate,
      flags: Set<String>.unmodifiable(<String>{
        'read',
        if (directory.canMutate) 'mutate-directory',
      }),
      bytes: Uint8List(0),
      otherTypeName: null,
      entry: null,
    );
  }

  factory _WASIPreview3FilesystemDescriptor.fromEntry({
    required int objectId,
    required String guestPath,
    required WASIPreview3FilesystemDirectoryEntry entry,
  }) {
    return _WASIPreview3FilesystemDescriptor._(
      objectId: objectId,
      guestPath: guestPath,
      kind: entry.kind,
      size: entry.size,
      directory: entry.directory,
      canMutate: entry.canMutate,
      flags: Set<String>.unmodifiable(<String>{
        'read',
        if (entry.kind == WASIPreview3FilesystemDescriptorKind.regularFile &&
            entry.canMutate)
          'write',
        if (entry.kind == WASIPreview3FilesystemDescriptorKind.directory &&
            entry.canMutate)
          'mutate-directory',
      }),
      bytes: Uint8List(0),
      otherTypeName: entry.otherTypeName,
      entry: entry,
    );
  }

  final int objectId;
  final String guestPath;
  final WASIPreview3FilesystemDescriptorKind kind;
  final BigInt size;
  final WASIPreview3FilesystemDirectory? directory;
  final bool canMutate;
  final Set<String> flags;
  final Uint8List bytes;
  final String? otherTypeName;
  final WASIPreview3FilesystemDirectoryEntry? entry;

  Object get appendSerializationKey =>
      metadata.objectIdentity ?? entry ?? (objectId, guestPath);

  BigInt get currentSize => entry?._size ?? size;

  bool get supportsSyncData => entry?._supportsSyncData ?? false;

  bool get supportsSync => entry?._supportsSync ?? false;

  WASIPreview3FilesystemMutationResult open() =>
      entry?._openWithFlags(flags) ??
      const WASIPreview3FilesystemMutationResult.ok();

  void close() => entry?._closeWithFlags(flags);

  _WASIPreview3FilesystemDescriptor withFlags(Iterable<String> flags) {
    return _WASIPreview3FilesystemDescriptor._(
      objectId: objectId,
      guestPath: guestPath,
      kind: kind,
      size: size,
      directory: directory,
      canMutate: canMutate,
      flags: Set<String>.unmodifiable(flags),
      bytes: bytes,
      otherTypeName: otherTypeName,
      entry: entry,
    );
  }

  WASIPreview3FilesystemMetadata get metadata =>
      entry?._currentMetadata() ??
      directory?._currentMetadata() ??
      const WASIPreview3FilesystemMetadata();

  Uint8List bytesFrom(BigInt offset, {int? maxBytes}) {
    final entry = this.entry;
    if (entry != null) {
      return entry._bytesFrom(offset, maxBytes: maxBytes);
    }
    final start = offset > BigInt.from(bytes.length)
        ? bytes.length
        : offset.toInt();
    final end = maxBytes == null || start + maxBytes > bytes.length
        ? bytes.length
        : start + maxBytes;
    return Uint8List.sublistView(bytes, start, end);
  }

  WASIPreview3FilesystemMutationResult writeAt(BigInt offset, Uint8List data) {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    final result = entry._writeAt(offset, data);
    return result.isOk ? _syncAfterWrite(entry) : result;
  }

  WASIPreview3FilesystemMutationResult setSize(BigInt nextSize) {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    final result = entry._setSizeTo(nextSize);
    return result.isOk ? _syncAfterWrite(entry) : result;
  }

  WASIPreview3FilesystemMutationResult _syncAfterWrite(
    WASIPreview3FilesystemDirectoryEntry entry,
  ) {
    if (flags.contains('file-integrity-sync')) {
      return entry._syncTo();
    }
    if (flags.contains('data-integrity-sync')) {
      return entry._syncDataTo();
    }
    return const WASIPreview3FilesystemMutationResult.ok();
  }

  WASIPreview3FilesystemMutationResult setTimes(
    WASIPreview3FilesystemTimestampUpdate update,
  ) {
    final entry = this.entry;
    if (entry != null) {
      return entry._setTimesTo(update);
    }
    final directory = this.directory;
    if (directory != null) {
      return directory._setTimesTo(update);
    }
    return const WASIPreview3FilesystemMutationResult.error(
      WASIPreview3FilesystemMutationError.readOnly,
    );
  }

  WASIPreview3FilesystemMutationResult advise(
    BigInt offset,
    BigInt length,
    String advice,
  ) {
    final entry = this.entry;
    if (entry == null || offset < BigInt.zero || length < BigInt.zero) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.invalid,
      );
    }
    return entry._adviseTo(offset, length, advice);
  }

  WASIPreview3FilesystemMutationResult syncData() {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.unsupported,
      );
    }
    return entry._syncDataTo();
  }

  WASIPreview3FilesystemMutationResult sync() {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.unsupported,
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

({WASIPreview3FilesystemTimestampUpdate? update, String? error})
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
    update: WASIPreview3FilesystemTimestampUpdate(
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

Set<String> _effectiveDescriptorFlags(
  Iterable<String> openFlags,
  Iterable<String> requestedFlags,
) {
  final flags = <String>{...requestedFlags};
  if (flags.isEmpty) {
    flags.add('read');
  }
  if (openFlags.contains('create')) {
    flags.add('write');
  }
  return flags;
}

bool _flagsContainMutation(Set<String> flags) {
  return flags.contains('write') || flags.contains('mutate-directory');
}

const int _fileStreamBufferSize = 65536;
const int _fileStreamChunkSize = 16384;
const int _directoryStreamBufferSize = 64;
final BigInt _maxHostCollectionLength = BigInt.from(0x7fffffff);

const Set<String> _adviceLabels = <String>{
  'normal',
  'sequential',
  'random',
  'will-need',
  'dont-need',
  'no-reuse',
};

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
  WASIPreview3FilesystemMutationResult result,
) {
  if (result.isOther) {
    final message = result.otherMessage;
    return _errorResult(
      'other',
      message == null ? _none() : _some(_stringData(message)),
    );
  }
  final error = result.error;
  return error == null ? _unitOk() : _errorResult(error.errorCode);
}

WasmComponentValueData _descriptorStatData(
  _WASIPreview3FilesystemDescriptor descriptor,
) {
  final metadata = descriptor.metadata;
  return _record(<WasmComponentValueData>[
    _descriptorTypeData(
      descriptor.kind,
      otherTypeName: descriptor.otherTypeName,
    ),
    _integerData(metadata.linkCount ?? BigInt.one),
    _integerData(metadata.size ?? descriptor.currentSize),
    _optionalInstantData(metadata.accessTimeNanos),
    _optionalInstantData(metadata.modificationTimeNanos),
    _optionalInstantData(metadata.statusChangeTimeNanos),
  ]);
}

WasmComponentValueData _directoryEntryData(
  WASIPreview3FilesystemDirectoryEntry entry,
) {
  return _record(<WasmComponentValueData>[
    _descriptorTypeData(entry.kind, otherTypeName: entry.otherTypeName),
    _stringData(entry.name),
  ]);
}

WasmComponentValueData _metadataHashData(
  _WASIPreview3FilesystemDescriptor descriptor,
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
  WASIPreview3FilesystemDescriptorKind kind, {
  String? otherTypeName,
}) {
  return switch (kind) {
    WASIPreview3FilesystemDescriptorKind.blockDevice => _variant(
      'block-device',
    ),
    WASIPreview3FilesystemDescriptorKind.characterDevice => _variant(
      'character-device',
    ),
    WASIPreview3FilesystemDescriptorKind.directory => _variant('directory'),
    WASIPreview3FilesystemDescriptorKind.fifo => _variant('fifo'),
    WASIPreview3FilesystemDescriptorKind.symbolicLink => _variant(
      'symbolic-link',
    ),
    WASIPreview3FilesystemDescriptorKind.regularFile => _variant(
      'regular-file',
    ),
    WASIPreview3FilesystemDescriptorKind.socket => _variant('socket'),
    WASIPreview3FilesystemDescriptorKind.other => _variant(
      'other',
      otherTypeName == null ? _none() : _some(_stringData(otherTypeName)),
    ),
  };
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

WasmComponentValueData _unitOk() => _ok();

WasmComponentValueData _errorResult(
  String code, [
  WasmComponentValueData? payload,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: _variant(code, payload),
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

WasmComponentValueData _variant(
  String label, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: _variantIndex(label),
    label: label,
    associatedValue: associatedValue,
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

int _variantIndex(String label) {
  final index = _filesystemVariantIndexes[label];
  return index ?? 0;
}

const Map<String, int> _filesystemVariantIndexes = <String, int>{
  'block-device': 0,
  'character-device': 1,
  'directory': 2,
  'fifo': 3,
  'symbolic-link': 4,
  'regular-file': 5,
  'socket': 6,
  'other': 7,
  'access': 0,
  'already': 1,
  'bad-descriptor': 2,
  'busy': 3,
  'deadlock': 4,
  'quota': 5,
  'exist': 6,
  'file-too-large': 7,
  'illegal-byte-sequence': 8,
  'in-progress': 9,
  'interrupted': 10,
  'invalid': 11,
  'io': 12,
  'is-directory': 13,
  'loop': 14,
  'too-many-links': 15,
  'message-size': 16,
  'name-too-long': 17,
  'no-device': 18,
  'no-entry': 19,
  'no-lock': 20,
  'insufficient-memory': 21,
  'insufficient-space': 22,
  'not-directory': 23,
  'not-empty': 24,
  'not-recoverable': 25,
  'unsupported': 26,
  'no-tty': 27,
  'no-such-device': 28,
  'overflow': 29,
  'not-permitted': 30,
  'pipe': 31,
  'read-only': 32,
  'invalid-seek': 33,
  'text-file-busy': 34,
  'cross-device': 35,
};

final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;
