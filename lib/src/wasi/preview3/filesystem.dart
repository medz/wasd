import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/async_values.dart';
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

/// Supplies the current byte length for a regular file.
typedef WASIPreview3FilesystemFileSizeProvider = BigInt Function();

/// Writes regular-file bytes starting at byte [offset].
typedef WASIPreview3FilesystemFileWriteCallback =
    WASIPreview3FilesystemMutationResult Function(
      BigInt offset,
      Uint8List bytes,
    );

/// Changes the byte length of a regular file.
typedef WASIPreview3FilesystemFileSetSizeCallback =
    WASIPreview3FilesystemMutationResult Function(BigInt size);

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
  readOnly('read-only');

  const WASIPreview3FilesystemMutationError(this.errorCode);

  /// WIT `error-code` variant label.
  final String errorCode;
}

/// Result returned by Preview3 filesystem mutation callbacks.
final class WASIPreview3FilesystemMutationResult {
  /// Creates a successful mutation result.
  const WASIPreview3FilesystemMutationResult.ok() : error = null;

  /// Creates a failed mutation result with a WASI filesystem [error].
  const WASIPreview3FilesystemMutationResult.error(this.error);

  /// WASI filesystem error reported by the mutation, or null on success.
  final WASIPreview3FilesystemMutationError? error;

  /// Whether the mutation succeeded.
  bool get isOk => error == null;
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
  /// Directory descriptor.
  directory,

  /// Symbolic-link descriptor.
  symbolicLink,

  /// Regular-file descriptor.
  regularFile,
}

/// Directory contents exposed through a WASI 0.3 filesystem preopen.
final class WASIPreview3FilesystemDirectory {
  /// Creates a directory model with stable [entries].
  WASIPreview3FilesystemDirectory({
    Iterable<WASIPreview3FilesystemDirectoryEntry> entries =
        const <WASIPreview3FilesystemDirectoryEntry>[],
    this.canMutate = false,
    this.mutationContext,
    WASIPreview3FilesystemDirectoryMutationCallback? createDirectory,
    WASIPreview3FilesystemDirectoryFileCreateCallback? createFile,
    WASIPreview3FilesystemDirectoryLinkCallback? link,
    WASIPreview3FilesystemDirectoryRenameCallback? rename,
    WASIPreview3FilesystemDirectorySymlinkCallback? symlink,
    WASIPreview3FilesystemDirectoryReadLinkCallback? readLink,
    WASIPreview3FilesystemDirectoryMutationCallback? removeDirectory,
    WASIPreview3FilesystemDirectoryMutationCallback? unlinkFile,
  }) : _entries = List<WASIPreview3FilesystemDirectoryEntry>.of(entries),
       _entriesProvider = null,
       _entryResolver = null,
       _createDirectory = createDirectory,
       _createFile = createFile,
       _link = link,
       _rename = rename,
       _symlink = symlink,
       _readLink = readLink,
       _removeDirectory = removeDirectory,
       _unlinkFile = unlinkFile;

  /// Creates a directory whose contents are loaded from callbacks.
  WASIPreview3FilesystemDirectory.dynamic({
    required WASIPreview3FilesystemDirectoryEntriesProvider entries,
    WASIPreview3FilesystemDirectoryEntryResolver? resolveEntry,
    this.canMutate = false,
    this.mutationContext,
    WASIPreview3FilesystemDirectoryMutationCallback? createDirectory,
    WASIPreview3FilesystemDirectoryFileCreateCallback? createFile,
    WASIPreview3FilesystemDirectoryLinkCallback? link,
    WASIPreview3FilesystemDirectoryRenameCallback? rename,
    WASIPreview3FilesystemDirectorySymlinkCallback? symlink,
    WASIPreview3FilesystemDirectoryReadLinkCallback? readLink,
    WASIPreview3FilesystemDirectoryMutationCallback? removeDirectory,
    WASIPreview3FilesystemDirectoryMutationCallback? unlinkFile,
  }) : _entries = <WASIPreview3FilesystemDirectoryEntry>[],
       _entriesProvider = entries,
       _entryResolver = resolveEntry,
       _createDirectory = createDirectory,
       _createFile = createFile,
       _link = link,
       _rename = rename,
       _symlink = symlink,
       _readLink = readLink,
       _removeDirectory = removeDirectory,
       _unlinkFile = unlinkFile;

  /// Entries returned by `descriptor.read-directory`.
  List<WASIPreview3FilesystemDirectoryEntry> get entries =>
      List<WASIPreview3FilesystemDirectoryEntry>.unmodifiable(_currentEntries);

  /// Whether descriptors opened for this directory can request mutation flags.
  final bool canMutate;

  /// Opaque host-specific context available to mutation callbacks.
  final Object? mutationContext;

  final List<WASIPreview3FilesystemDirectoryEntry> _entries;
  final WASIPreview3FilesystemDirectoryEntriesProvider? _entriesProvider;
  final WASIPreview3FilesystemDirectoryEntryResolver? _entryResolver;
  final WASIPreview3FilesystemDirectoryMutationCallback? _createDirectory;
  final WASIPreview3FilesystemDirectoryFileCreateCallback? _createFile;
  final WASIPreview3FilesystemDirectoryLinkCallback? _link;
  final WASIPreview3FilesystemDirectoryRenameCallback? _rename;
  final WASIPreview3FilesystemDirectorySymlinkCallback? _symlink;
  final WASIPreview3FilesystemDirectoryReadLinkCallback? _readLink;
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
  /// Creates a directory entry.
  WASIPreview3FilesystemDirectoryEntry.directory(
    this.name, {
    WASIPreview3FilesystemDirectory? directory,
  }) : kind = WASIPreview3FilesystemDescriptorKind.directory,
       size = BigInt.zero,
       directory = directory ?? WASIPreview3FilesystemDirectory(),
       canMutate = directory?.canMutate ?? false,
       _bytes = Uint8List(0),
       _readBytes = null,
       _currentSize = null,
       _writeBytes = null,
       _setSize = null,
       _linkTarget = null;

  /// Creates a symbolic-link entry.
  WASIPreview3FilesystemDirectoryEntry.symbolicLink(
    this.name, {
    required String target,
  }) : kind = WASIPreview3FilesystemDescriptorKind.symbolicLink,
       size = BigInt.from(target.length),
       directory = null,
       canMutate = false,
       _bytes = Uint8List(0),
       _readBytes = null,
       _currentSize = null,
       _writeBytes = null,
       _setSize = null,
       _linkTarget = target;

  /// Creates a regular-file entry.
  WASIPreview3FilesystemDirectoryEntry.regularFile(
    this.name, {
    BigInt? size,
    List<int> bytes = const <int>[],
    this.canMutate = false,
    WASIPreview3FilesystemFileBytesProvider? readBytes,
    WASIPreview3FilesystemFileSizeProvider? currentSize,
    WASIPreview3FilesystemFileWriteCallback? writeBytes,
    WASIPreview3FilesystemFileSetSizeCallback? setSize,
  }) : _bytes = Uint8List.fromList(bytes),
       _readBytes = readBytes,
       _currentSize = currentSize,
       _writeBytes = writeBytes,
       _setSize = setSize,
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

  /// Immutable file contents for regular-file entries.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  Uint8List _bytes;
  final WASIPreview3FilesystemFileBytesProvider? _readBytes;
  final WASIPreview3FilesystemFileSizeProvider? _currentSize;
  final WASIPreview3FilesystemFileWriteCallback? _writeBytes;
  final WASIPreview3FilesystemFileSetSizeCallback? _setSize;
  final String? _linkTarget;

  BigInt get _size => _currentSize?.call() ?? size;

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

  WASIPreview3FilesystemDirectoryEntry _renamed(String name) {
    return switch (kind) {
      WASIPreview3FilesystemDescriptorKind.directory =>
        WASIPreview3FilesystemDirectoryEntry.directory(
          name,
          directory: directory,
        ),
      WASIPreview3FilesystemDescriptorKind.symbolicLink =>
        WASIPreview3FilesystemDirectoryEntry.symbolicLink(
          name,
          target: _linkTarget ?? '',
        ),
      WASIPreview3FilesystemDescriptorKind.regularFile =>
        WASIPreview3FilesystemDirectoryEntry.regularFile(
          name,
          size: size,
          bytes: _bytes,
          canMutate: canMutate,
          readBytes: _readBytes,
          currentSize: _currentSize,
          writeBytes: _writeBytes,
          setSize: _setSize,
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
  }) {
    for (final entry in preopens.entries) {
      final guestPath = _normalizePreopenPath(entry.key);
      final descriptor = _WASIPreview3FilesystemDescriptor.directory(
        handle: _nextHandle++,
        objectId: _nextObjectId++,
        guestPath: guestPath,
        directory: entry.value,
      );
      _descriptors[descriptor.handle] = descriptor;
      _preopens.add((descriptor.handle, guestPath));
    }
  }

  int _nextHandle = 1;
  int _nextObjectId = 1;
  final _preopens = <(int, String)>[];
  final _descriptors = <int, _WASIPreview3FilesystemDescriptor>{};

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
        'wasi:filesystem/types@0.3.0.descriptor.advise': (args) =>
            _unitResultForDescriptor(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.sync-data': (args) =>
            _unitResultForDescriptor(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.get-flags': (args) =>
            _getFlags(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.get-type': (args) =>
            _getType(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.set-size': (args) =>
            _setSize(_handle(args[0]), _u64(args[1])),
        'wasi:filesystem/types@0.3.0.descriptor.set-times': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.read-directory': (args) =>
            _readDirectory(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.sync': (args) =>
            _unitResultForDescriptor(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.create-directory-at': (args) =>
            _createDirectoryAt(_handle(args[0]), args[1] as String),
        'wasi:filesystem/types@0.3.0.descriptor.stat': (args) =>
            _stat(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.stat-at': (args) =>
            _statAt(_handle(args[0]), args[2] as String),
        'wasi:filesystem/types@0.3.0.descriptor.set-times-at': (args) =>
            _readonlyUnitResult(_handle(args[0])),
        'wasi:filesystem/types@0.3.0.descriptor.link-at': (args) => _linkAt(
          _handle(args[0]),
          args[2] as String,
          _handle(args[3]),
          args[4] as String,
        ),
        'wasi:filesystem/types@0.3.0.descriptor.open-at': (args) => _openAt(
          _handle(args[0]),
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
            _metadataHashAt(_handle(args[0]), args[2] as String),
      });

  WasmComponentValueData _getDirectories() {
    return _list([
      for (final (handle, guestPath) in _preopens)
        _tuple(<WasmComponentValueData>[
          _integerData(handle),
          _stringData(guestPath),
        ]),
    ]);
  }

  List<Object?> _readViaStream(int handle, BigInt offset) {
    final stream = WASIComponentStream<int>('filesystem-read-$handle');
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-read-result-$handle',
    );
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      stream.writable.close();
      result.writable.complete(_errorResult('bad-descriptor'));
      return <Object?>[stream, result];
    }
    if (descriptor.kind == WASIPreview3FilesystemDescriptorKind.directory) {
      stream.writable.close();
      result.writable.complete(_errorResult('is-directory'));
      return <Object?>[stream, result];
    }
    if (descriptor.kind != WASIPreview3FilesystemDescriptorKind.regularFile) {
      stream.writable.close();
      result.writable.complete(_errorResult('invalid'));
      return <Object?>[stream, result];
    }
    stream.writable.writeAll(descriptor.bytesFrom(offset));
    stream.writable.close();
    result.writable.complete(_unitOk());
    return <Object?>[stream, result];
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
    final descriptor = _descriptors[handle];
    final error = _writableDescriptorError(descriptor);
    if (error != null) {
      result.writable.complete(_errorResult(error));
      return result;
    }
    unawaited(_drainWriteStream(descriptor!, stream, offset, result));
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
    final descriptor = _descriptors[handle];
    final error = _writableDescriptorError(descriptor);
    if (error != null) {
      result.writable.complete(_errorResult(error));
      return result;
    }
    unawaited(
      _drainWriteStream(descriptor!, stream, descriptor.currentSize, result),
    );
    return result;
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
          _completeWriteResult(result, _mutationResult(mutation));
          return;
        }
        offset += BigInt.from(chunk.length);
      }
      _completeWriteResult(result, _unitOk());
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
    return null;
  }

  WasmComponentValueData _unitResultForDescriptor(int handle) {
    if (!_descriptors.containsKey(handle)) {
      return _errorResult('bad-descriptor');
    }
    return _unitOk();
  }

  WasmComponentValueData _readonlyUnitResult(int handle) {
    if (!_descriptors.containsKey(handle)) {
      return _errorResult('bad-descriptor');
    }
    return _errorResult('read-only');
  }

  WasmComponentValueData _getFlags(int handle) {
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(
      _flagsData(<String>[
        'read',
        if (descriptor.kind ==
                WASIPreview3FilesystemDescriptorKind.regularFile &&
            descriptor.canMutate)
          'write',
        if (descriptor.kind == WASIPreview3FilesystemDescriptorKind.directory &&
            descriptor.canMutate)
          'mutate-directory',
      ]),
    );
  }

  WasmComponentValueData _setSize(int handle, BigInt size) {
    final descriptor = _descriptors[handle];
    final error = _writableDescriptorError(descriptor);
    if (error != null) {
      return _errorResult(error);
    }
    return _mutationResult(descriptor!.setSize(size));
  }

  WasmComponentValueData _getType(int handle) {
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_descriptorTypeData(descriptor.kind));
  }

  List<Object?> _readDirectory(int handle) {
    final stream = WASIComponentStream<WasmComponentValueData>(
      'filesystem-directory-$handle',
    );
    final result = WASIComponentFuture<WasmComponentValueData>(
      'filesystem-directory-result-$handle',
    );
    final descriptor = _descriptors[handle];
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
    for (final entry in descriptor.directory!._currentEntries) {
      stream.writable.write(_directoryEntryData(entry));
    }
    stream.writable.close();
    result.writable.complete(_unitOk());
    return <Object?>[stream, result];
  }

  WasmComponentValueData _stat(int handle) {
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_descriptorStatData(descriptor));
  }

  WasmComponentValueData _statAt(int handle, String path) {
    final descriptor = _resolveAt(handle, path);
    if (descriptor == null) {
      return _errorResult('no-entry');
    }
    return _ok(_descriptorStatData(descriptor));
  }

  WasmComponentValueData _createDirectoryAt(int handle, String path) {
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

  WasmComponentValueData _removeDirectoryAt(int handle, String path) {
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
    String oldPath,
    int newHandle,
    String newPath,
  ) {
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
    return _ok(_stringData(result.target ?? ''));
  }

  WasmComponentValueData _openAt(
    int handle,
    String path,
    WasmComponentValueData openFlags,
    WasmComponentValueData flags,
  ) {
    final base = _descriptors[handle];
    if (base == null) {
      return _errorResult('bad-descriptor');
    }
    if ((_flagsContainMutation(flags) ||
            _openFlagsContainMutation(openFlags)) &&
        !base.canMutate) {
      return _errorResult('read-only');
    }
    final descriptor = _resolveAt(handle, path);
    if (descriptor == null) {
      if (openFlags.labels.contains('create')) {
        return _createFileAt(handle, path, flags);
      }
      return _errorResult(
        _pathIsPermitted(path) ? 'no-entry' : 'not-permitted',
      );
    }
    if (openFlags.labels.contains('create') &&
        openFlags.labels.contains('exclusive')) {
      return _errorResult('exist');
    }
    if (openFlags.labels.contains('directory') &&
        descriptor.kind != WASIPreview3FilesystemDescriptorKind.directory) {
      return _errorResult('not-directory');
    }
    if (_flagsContainMutation(flags) && !descriptor.canMutate) {
      return _errorResult('read-only');
    }
    if (openFlags.labels.contains('truncate')) {
      if (!descriptor.canMutate) {
        return _errorResult('read-only');
      }
      final mutation = descriptor.setSize(BigInt.zero);
      if (!mutation.isOk) {
        return _mutationResult(mutation);
      }
    }
    final opened = descriptor.copyWithHandle(_nextHandle++);
    _descriptors[opened.handle] = opened;
    return _ok(_integerData(opened.handle));
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
    final created = parent.directory!._createFileAt(target.name);
    if (!created.result.isOk) {
      return _mutationResult(created.result);
    }
    final guestPath = '${parent.guestPath}/${target.name}'.replaceAll(
      '//',
      '/',
    );
    final descriptor = _WASIPreview3FilesystemDescriptor.fromEntry(
      handle: _nextHandle++,
      objectId: _objectIdForPath(guestPath),
      guestPath: guestPath,
      entry: created.entry!,
    );
    if (_flagsContainMutation(flags) && !descriptor.canMutate) {
      return _errorResult('read-only');
    }
    _descriptors[descriptor.handle] = descriptor;
    return _ok(_integerData(descriptor.handle));
  }

  bool _isSameObject(int left, int right) {
    final leftDescriptor = _descriptors[left];
    final rightDescriptor = _descriptors[right];
    return leftDescriptor != null &&
        rightDescriptor != null &&
        leftDescriptor.objectId == rightDescriptor.objectId;
  }

  WasmComponentValueData _metadataHash(int handle) {
    final descriptor = _descriptors[handle];
    if (descriptor == null) {
      return _errorResult('bad-descriptor');
    }
    return _ok(_metadataHashData(descriptor));
  }

  WasmComponentValueData _metadataHashAt(int handle, String path) {
    final descriptor = _resolveAt(handle, path);
    if (descriptor == null) {
      return _errorResult('no-entry');
    }
    return _ok(_metadataHashData(descriptor));
  }

  _WASIPreview3FilesystemDescriptor? _resolveAt(int handle, String path) {
    final base = _descriptors[handle];
    if (base?.directory == null || !_pathIsPermitted(path)) {
      return null;
    }
    if (path.isEmpty || path == '.') {
      return base;
    }
    var current = base!;
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      final directory = current.directory;
      if (directory == null) {
        return null;
      }
      final entry = directory._entryNamed(segment);
      if (entry == null) {
        return null;
      }
      final guestPath = '${current.guestPath}/$segment'.replaceAll('//', '/');
      current = _WASIPreview3FilesystemDescriptor.fromEntry(
        handle: _nextHandle,
        objectId: _objectIdForPath(guestPath),
        guestPath: guestPath,
        entry: entry,
      );
    }
    return current;
  }

  int _objectIdForPath(String path) {
    var hash = 0x811c9dc5;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  ({_WASIPreview3FilesystemDescriptor? parent, String name, String? error})
  _resolveMutationParent(int handle, String path) {
    final base = _descriptors[handle];
    if (base == null) {
      return (parent: null, name: '', error: 'bad-descriptor');
    }
    if (base.directory == null) {
      return (parent: null, name: '', error: 'not-directory');
    }
    if (!_pathIsPermitted(path)) {
      return (parent: null, name: '', error: 'not-permitted');
    }
    final segments = path
        .split('/')
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList();
    if (segments.isEmpty || !_isSimplePathSegment(segments.last)) {
      return (parent: null, name: '', error: 'invalid');
    }
    var current = base;
    for (final segment in segments.take(segments.length - 1)) {
      final directory = current.directory;
      if (directory == null) {
        return (parent: null, name: '', error: 'not-directory');
      }
      final entry = directory._entryNamed(segment);
      if (entry == null) {
        return (parent: null, name: '', error: 'no-entry');
      }
      if (entry.kind != WASIPreview3FilesystemDescriptorKind.directory) {
        return (parent: null, name: '', error: 'not-directory');
      }
      final guestPath = '${current.guestPath}/$segment'.replaceAll('//', '/');
      current = _WASIPreview3FilesystemDescriptor.fromEntry(
        handle: _nextHandle,
        objectId: _objectIdForPath(guestPath),
        guestPath: guestPath,
        entry: entry,
      );
    }
    return (parent: current, name: segments.last, error: null);
  }
}

final class _WASIPreview3FilesystemDescriptor {
  const _WASIPreview3FilesystemDescriptor._({
    required this.handle,
    required this.objectId,
    required this.guestPath,
    required this.kind,
    required this.size,
    required this.directory,
    required this.canMutate,
    required this.bytes,
    required this.entry,
  });

  factory _WASIPreview3FilesystemDescriptor.directory({
    required int handle,
    required int objectId,
    required String guestPath,
    required WASIPreview3FilesystemDirectory directory,
  }) {
    return _WASIPreview3FilesystemDescriptor._(
      handle: handle,
      objectId: objectId,
      guestPath: guestPath,
      kind: WASIPreview3FilesystemDescriptorKind.directory,
      size: BigInt.zero,
      directory: directory,
      canMutate: directory.canMutate,
      bytes: Uint8List(0),
      entry: null,
    );
  }

  factory _WASIPreview3FilesystemDescriptor.fromEntry({
    required int handle,
    required int objectId,
    required String guestPath,
    required WASIPreview3FilesystemDirectoryEntry entry,
  }) {
    return _WASIPreview3FilesystemDescriptor._(
      handle: handle,
      objectId: objectId,
      guestPath: guestPath,
      kind: entry.kind,
      size: entry.size,
      directory: entry.directory,
      canMutate: entry.canMutate,
      bytes: Uint8List(0),
      entry: entry,
    );
  }

  final int handle;
  final int objectId;
  final String guestPath;
  final WASIPreview3FilesystemDescriptorKind kind;
  final BigInt size;
  final WASIPreview3FilesystemDirectory? directory;
  final bool canMutate;
  final Uint8List bytes;
  final WASIPreview3FilesystemDirectoryEntry? entry;

  BigInt get currentSize => entry?._size ?? size;

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

  WASIPreview3FilesystemMutationResult writeAt(BigInt offset, Uint8List data) {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    return entry._writeAt(offset, data);
  }

  WASIPreview3FilesystemMutationResult setSize(BigInt nextSize) {
    final entry = this.entry;
    if (entry == null) {
      return const WASIPreview3FilesystemMutationResult.error(
        WASIPreview3FilesystemMutationError.readOnly,
      );
    }
    return entry._setSizeTo(nextSize);
  }

  _WASIPreview3FilesystemDescriptor copyWithHandle(int handle) {
    return _WASIPreview3FilesystemDescriptor._(
      handle: handle,
      objectId: objectId,
      guestPath: guestPath,
      kind: kind,
      size: size,
      directory: directory,
      canMutate: canMutate,
      bytes: bytes,
      entry: entry,
    );
  }
}

String _normalizePreopenPath(String path) {
  if (path.isEmpty) {
    return '/';
  }
  return path.startsWith('/') ? path : '/$path';
}

bool _pathIsPermitted(String path) {
  if (path.startsWith('/') || path.contains('\u0000')) {
    return false;
  }
  for (final segment in path.split('/')) {
    if (segment == '..') {
      return false;
    }
  }
  return true;
}

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

bool _openFlagsContainMutation(WasmComponentValueData flags) {
  return flags.labels.contains('create') || flags.labels.contains('truncate');
}

WasmComponentValueData _mutationResult(
  WASIPreview3FilesystemMutationResult result,
) {
  final error = result.error;
  return error == null ? _unitOk() : _errorResult(error.errorCode);
}

WasmComponentValueData _descriptorStatData(
  _WASIPreview3FilesystemDescriptor descriptor,
) {
  return _record(<WasmComponentValueData>[
    _descriptorTypeData(descriptor.kind),
    _integerData(BigInt.one),
    _integerData(descriptor.currentSize),
    _none(),
    _none(),
    _none(),
  ]);
}

WasmComponentValueData _directoryEntryData(
  WASIPreview3FilesystemDirectoryEntry entry,
) {
  return _record(<WasmComponentValueData>[
    _descriptorTypeData(entry.kind),
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
  WASIPreview3FilesystemDescriptorKind kind,
) {
  return _variant(switch (kind) {
    WASIPreview3FilesystemDescriptorKind.directory => 'directory',
    WASIPreview3FilesystemDescriptorKind.symbolicLink => 'symbolic-link',
    WASIPreview3FilesystemDescriptorKind.regularFile => 'regular-file',
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

WasmComponentValueData _unitOk() => _ok();

WasmComponentValueData _errorResult(String code) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: _variant(code),
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
