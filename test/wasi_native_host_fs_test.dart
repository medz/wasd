@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

import 'support/wasm_fixtures.dart';

const int _rightFdRead = 1 << 1;
const int _rightFdSeek = 1 << 2;
const int _rightFdTell = 1 << 5;
const int _rightFdWrite = 1 << 6;
const int _rightFdAllocate = 1 << 8;
const int _rightFdReaddir = 1 << 14;
const int _rightFdFilestatGet = 1 << 21;
const int _rightFdFilestatSetSize = 1 << 22;
const int _errnoExist = 20;
const int _errnoInval = 28;
const int _errnoIsdir = 31;
const int _errnoNoent = 44;
const int _errnoNotdir = 54;
const int _errnoNotempty = 55;
const int _filestatFiletypeOffset = 16;
const int _filestatSizeOffset = 32;
const int _filetypeDirectory = 3;
const int _filetypeRegularFile = 4;
const int _oflagCreat = 1;
const int _oflagDirectory = 2;
const int _oflagExcl = 4;
const int _oflagTrunc = 8;
const int _direntSize = 24;
const int _direntNextOffset = 0;
const int _direntNameLengthOffset = 16;
const int _direntTypeOffset = 20;

int _getUint64Le(ByteData data, int offset) {
  final low = data.getUint32(offset, Endian.little);
  final high = data.getUint32(offset + 4, Endian.little);
  return low | (high << 32);
}

List<({String name, int next, int type})> _readDirents(
  Uint8List bytes,
  ByteData data,
  int ptr,
  int length,
) {
  final entries = <({String name, int next, int type})>[];
  var offset = ptr;
  final end = ptr + length;
  while (offset + _direntSize <= end) {
    final next = _getUint64Le(data, offset + _direntNextOffset);
    final nameLength = data.getUint32(
      offset + _direntNameLengthOffset,
      Endian.little,
    );
    final type = bytes[offset + _direntTypeOffset];
    final namePtr = offset + _direntSize;
    final nameEnd = namePtr + nameLength;
    if (nameEnd > end) {
      break;
    }
    entries.add((
      name: utf8.decode(bytes.sublist(namePtr, nameEnd)),
      next: next,
      type: type,
    ));
    offset = nameEnd;
  }
  return entries;
}

void _writeSingleIov({
  required Uint8List bytes,
  required ByteData data,
  required int iovPtr,
  required int bufferPtr,
  required String value,
}) {
  final encoded = utf8.encode(value);
  bytes.setAll(bufferPtr, encoded);
  data.setUint32(iovPtr, bufferPtr, Endian.little);
  data.setUint32(iovPtr + 4, encoded.length, Endian.little);
}

void main() {
  test('native preopens read files from the host filesystem', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_host_fs_');
    addTearDown(() => temp.delete(recursive: true));
    File('${temp.path}/hello.txt').writeAsStringSync('host-backed');
    Directory('${temp.path}/dir').createSync();

    final wasi = WASI(preopens: {'/host': temp.path});
    final result = await WebAssembly.instantiate(
      wasiStartModuleBytes().buffer,
      wasi.imports,
    );
    final instance = result.instance;
    final preview1 = wasi.imports['wasi_snapshot_preview1']!;
    final pathOpen = preview1['path_open'] as FunctionImportExportValue;
    final fdRead = preview1['fd_read'] as FunctionImportExportValue;
    final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
    final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
    final fdTell = preview1['fd_tell'] as FunctionImportExportValue;
    final fdFilestatGet =
        preview1['fd_filestat_get'] as FunctionImportExportValue;
    final fdClose = preview1['fd_close'] as FunctionImportExportValue;
    final memory = (instance.exports['memory'] as MemoryImportExportValue).ref;
    wasi.finalizeBindings(instance, memory: memory);

    final bytes = Uint8List.view(memory.buffer);
    final data = ByteData.view(memory.buffer);
    final path = utf8.encode('hello.txt');
    const pathPtr = 1024;
    const openedFdPtr = 1056;
    const iovPtr = 1072;
    const bufferPtr = 1104;
    const nreadPtr = 1136;
    const filestatPtr = 1152;
    const newOffsetPtr = 1232;
    const preadBufferPtr = 1248;
    bytes.setAll(pathPtr, path);

    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        path.length,
        0,
        _rightFdRead | _rightFdSeek | _rightFdTell | _rightFdFilestatGet,
        0,
        0,
        openedFdPtr,
      ]),
      0,
    );
    final fd = data.getUint32(openedFdPtr, Endian.little);
    expect(fd, greaterThanOrEqualTo(64));

    expect(fdFilestatGet.ref([fd, filestatPtr]), 0);
    expect(
      data.getUint64(filestatPtr + _filestatSizeOffset, Endian.little),
      'host-backed'.length,
    );

    data.setUint32(iovPtr, preadBufferPtr, Endian.little);
    data.setUint32(iovPtr + 4, 4, Endian.little);
    expect(fdPread.ref([fd, iovPtr, 1, 5, nreadPtr]), 0);
    var nread = data.getUint32(nreadPtr, Endian.little);
    expect(
      utf8.decode(bytes.sublist(preadBufferPtr, preadBufferPtr + nread)),
      'back',
    );
    expect(fdTell.ref([fd, newOffsetPtr]), 0);
    expect(data.getUint64(newOffsetPtr, Endian.little), 0);

    expect(fdSeek.ref([fd, -'backed'.length, 2, newOffsetPtr]), 0);
    expect(data.getUint64(newOffsetPtr, Endian.little), 5);

    data.setUint32(iovPtr, bufferPtr, Endian.little);
    data.setUint32(iovPtr + 4, 32, Endian.little);
    expect(fdRead.ref([fd, iovPtr, 1, nreadPtr]), 0);
    nread = data.getUint32(nreadPtr, Endian.little);
    expect(utf8.decode(bytes.sublist(bufferPtr, bufferPtr + nread)), 'backed');
    expect(fdTell.ref([fd, newOffsetPtr]), 0);
    expect(data.getUint64(newOffsetPtr, Endian.little), 'host-backed'.length);

    expect(fdClose.ref([fd]), 0);

    final directoryPath = utf8.encode('dir');
    bytes.setAll(pathPtr, directoryPath);
    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        directoryPath.length,
        _oflagDirectory,
        0,
        0,
        0,
        openedFdPtr,
      ]),
      0,
    );
    expect(fdClose.ref([data.getUint32(openedFdPtr, Endian.little)]), 0);
  });

  test('native host files persist writes, resize, and create', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_host_write_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/mutable.txt')..writeAsStringSync('abcdef');
    final truncateFile = File('${temp.path}/truncate.txt')
      ..writeAsStringSync('truncate-me');

    final wasi = WASI(preopens: {'/host': temp.path});
    final result = await WebAssembly.instantiate(
      wasiStartModuleBytes().buffer,
      wasi.imports,
    );
    final instance = result.instance;
    final preview1 = wasi.imports['wasi_snapshot_preview1']!;
    final pathOpen = preview1['path_open'] as FunctionImportExportValue;
    final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
    final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
    final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
    final fdTell = preview1['fd_tell'] as FunctionImportExportValue;
    final fdFilestatSetSize =
        preview1['fd_filestat_set_size'] as FunctionImportExportValue;
    final fdAllocate = preview1['fd_allocate'] as FunctionImportExportValue;
    final fdClose = preview1['fd_close'] as FunctionImportExportValue;
    final memory = (instance.exports['memory'] as MemoryImportExportValue).ref;
    wasi.finalizeBindings(instance, memory: memory);

    final bytes = Uint8List.view(memory.buffer);
    final data = ByteData.view(memory.buffer);
    final path = utf8.encode('mutable.txt');
    const pathPtr = 1024;
    const openedFdPtr = 1056;
    const iovPtr = 1072;
    const writeBufferPtr = 1104;
    const nwrittenPtr = 1152;
    const newOffsetPtr = 1168;
    bytes.setAll(pathPtr, path);

    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        path.length,
        0,
        _rightFdRead |
            _rightFdWrite |
            _rightFdSeek |
            _rightFdTell |
            _rightFdAllocate |
            _rightFdFilestatGet |
            _rightFdFilestatSetSize,
        0,
        0,
        openedFdPtr,
      ]),
      0,
    );
    final fd = data.getUint32(openedFdPtr, Endian.little);

    expect(fdSeek.ref([fd, 0, 2, newOffsetPtr]), 0);
    _writeSingleIov(
      bytes: bytes,
      data: data,
      iovPtr: iovPtr,
      bufferPtr: writeBufferPtr,
      value: '++',
    );
    expect(fdWrite.ref([fd, iovPtr, 1, nwrittenPtr]), 0);
    expect(data.getUint32(nwrittenPtr, Endian.little), 2);
    expect(file.readAsStringSync(), 'abcdef++');
    expect(fdTell.ref([fd, newOffsetPtr]), 0);
    expect(data.getUint64(newOffsetPtr, Endian.little), 8);

    _writeSingleIov(
      bytes: bytes,
      data: data,
      iovPtr: iovPtr,
      bufferPtr: writeBufferPtr,
      value: 'XY',
    );
    expect(fdPwrite.ref([fd, iovPtr, 1, 2, nwrittenPtr]), 0);
    expect(data.getUint32(nwrittenPtr, Endian.little), 2);
    expect(file.readAsStringSync(), 'abXYef++');
    expect(fdTell.ref([fd, newOffsetPtr]), 0);
    expect(data.getUint64(newOffsetPtr, Endian.little), 8);

    expect(fdFilestatSetSize.ref([fd, 5]), 0);
    expect(file.readAsStringSync(), 'abXYe');

    expect(fdAllocate.ref([fd, 8, 3]), 0);
    expect(file.lengthSync(), 11);
    expect(file.readAsBytesSync().take(5), utf8.encode('abXYe'));

    expect(fdClose.ref([fd]), 0);

    final truncatePath = utf8.encode('truncate.txt');
    bytes.setAll(pathPtr, truncatePath);
    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        truncatePath.length,
        _oflagTrunc,
        _rightFdRead | _rightFdWrite,
        0,
        0,
        openedFdPtr,
      ]),
      0,
    );
    final truncateFd = data.getUint32(openedFdPtr, Endian.little);
    expect(truncateFile.readAsStringSync(), isEmpty);
    expect(fdClose.ref([truncateFd]), 0);

    bytes.setAll(pathPtr, path);
    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        path.length,
        _oflagCreat | _oflagExcl,
        _rightFdRead,
        0,
        0,
        openedFdPtr,
      ]),
      _errnoExist,
    );

    final createdPath = utf8.encode('created.txt');
    bytes.setAll(pathPtr, createdPath);
    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        createdPath.length,
        _oflagCreat,
        _rightFdRead | _rightFdWrite,
        0,
        0,
        openedFdPtr,
      ]),
      0,
    );
    final createdFd = data.getUint32(openedFdPtr, Endian.little);
    _writeSingleIov(
      bytes: bytes,
      data: data,
      iovPtr: iovPtr,
      bufferPtr: writeBufferPtr,
      value: 'created',
    );
    expect(fdWrite.ref([createdFd, iovPtr, 1, nwrittenPtr]), 0);
    expect(File('${temp.path}/created.txt').readAsStringSync(), 'created');
    expect(fdClose.ref([createdFd]), 0);
  });

  test(
    'native host path mutations create and remove real filesystem entries',
    () async {
      final temp = await Directory.systemTemp.createTemp('wasd_host_mutate_');
      addTearDown(() => temp.delete(recursive: true));
      File('${temp.path}/delete.txt').writeAsStringSync('delete');
      File('${temp.path}/slash.txt').writeAsStringSync('slash');
      File('${temp.path}/not-dir.txt').writeAsStringSync('file');
      Directory('${temp.path}/empty').createSync();
      final nonEmpty = Directory('${temp.path}/non-empty')..createSync();
      File('${nonEmpty.path}/child.txt').writeAsStringSync('child');

      final wasi = WASI(preopens: {'/host': temp.path});
      final result = await WebAssembly.instantiate(
        wasiStartModuleBytes().buffer,
        wasi.imports,
      );
      final instance = result.instance;
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      final pathCreateDirectory =
          preview1['path_create_directory'] as FunctionImportExportValue;
      final pathUnlinkFile =
          preview1['path_unlink_file'] as FunctionImportExportValue;
      final pathRemoveDirectory =
          preview1['path_remove_directory'] as FunctionImportExportValue;
      final memory =
          (instance.exports['memory'] as MemoryImportExportValue).ref;
      wasi.finalizeBindings(instance, memory: memory);

      final bytes = Uint8List.view(memory.buffer);
      const pathPtr = 1024;

      var path = utf8.encode('created-dir');
      bytes.setAll(pathPtr, path);
      expect(pathCreateDirectory.ref([3, pathPtr, path.length]), 0);
      expect(Directory('${temp.path}/created-dir').existsSync(), isTrue);

      expect(pathCreateDirectory.ref([3, pathPtr, path.length]), _errnoExist);

      path = utf8.encode('delete.txt');
      bytes.setAll(pathPtr, path);
      expect(pathUnlinkFile.ref([3, pathPtr, path.length]), 0);
      expect(File('${temp.path}/delete.txt').existsSync(), isFalse);

      path = utf8.encode('slash.txt/');
      bytes.setAll(pathPtr, path);
      expect(pathUnlinkFile.ref([3, pathPtr, path.length]), _errnoNotdir);
      expect(File('${temp.path}/slash.txt').existsSync(), isTrue);

      path = utf8.encode('created-dir');
      bytes.setAll(pathPtr, path);
      expect(pathUnlinkFile.ref([3, pathPtr, path.length]), _errnoIsdir);
      expect(Directory('${temp.path}/created-dir').existsSync(), isTrue);

      path = utf8.encode('not-dir.txt');
      bytes.setAll(pathPtr, path);
      expect(pathRemoveDirectory.ref([3, pathPtr, path.length]), _errnoNotdir);
      expect(File('${temp.path}/not-dir.txt').existsSync(), isTrue);

      path = utf8.encode('non-empty');
      bytes.setAll(pathPtr, path);
      expect(
        pathRemoveDirectory.ref([3, pathPtr, path.length]),
        _errnoNotempty,
      );
      expect(Directory('${temp.path}/non-empty').existsSync(), isTrue);

      path = utf8.encode('empty');
      bytes.setAll(pathPtr, path);
      expect(pathRemoveDirectory.ref([3, pathPtr, path.length]), 0);
      expect(Directory('${temp.path}/empty').existsSync(), isFalse);

      path = utf8.encode('created-dir');
      bytes.setAll(pathPtr, path);
      expect(pathRemoveDirectory.ref([3, pathPtr, path.length]), 0);
      expect(Directory('${temp.path}/created-dir').existsSync(), isFalse);

      path = utf8.encode('.');
      bytes.setAll(pathPtr, path);
      expect(
        pathRemoveDirectory.ref([3, pathPtr, path.length]),
        _errnoNotempty,
      );
      expect(Directory(temp.path).existsSync(), isTrue);

      path = utf8.encode('missing');
      bytes.setAll(pathPtr, path);
      expect(pathRemoveDirectory.ref([3, pathPtr, path.length]), _errnoNoent);
    },
  );

  test('native host path_rename mutates real filesystem entries', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_host_rename_');
    addTearDown(() => temp.delete(recursive: true));
    File('${temp.path}/source.txt').writeAsStringSync('source');
    File('${temp.path}/replace.txt').writeAsStringSync('replace');
    final directory = Directory('${temp.path}/dir-source')..createSync();
    File('${directory.path}/child.txt').writeAsStringSync('child');
    Directory('${temp.path}/dir-target').createSync();
    final nonEmptyTarget = Directory('${temp.path}/non-empty-target')
      ..createSync();
    File('${nonEmptyTarget.path}/child.txt').writeAsStringSync('target-child');

    final wasi = WASI(preopens: {'/host': temp.path});
    final result = await WebAssembly.instantiate(
      wasiStartModuleBytes().buffer,
      wasi.imports,
    );
    final instance = result.instance;
    final preview1 = wasi.imports['wasi_snapshot_preview1']!;
    final pathRename = preview1['path_rename'] as FunctionImportExportValue;
    final memory = (instance.exports['memory'] as MemoryImportExportValue).ref;
    wasi.finalizeBindings(instance, memory: memory);

    final bytes = Uint8List.view(memory.buffer);
    const oldPathPtr = 1024;
    const newPathPtr = 1088;

    var oldPath = utf8.encode('source.txt');
    var newPath = utf8.encode('renamed.txt');
    bytes.setAll(oldPathPtr, oldPath);
    bytes.setAll(newPathPtr, newPath);
    expect(
      pathRename.ref([
        3,
        oldPathPtr,
        oldPath.length,
        3,
        newPathPtr,
        newPath.length,
      ]),
      0,
    );
    expect(File('${temp.path}/source.txt').existsSync(), isFalse);
    expect(File('${temp.path}/renamed.txt').readAsStringSync(), 'source');

    oldPath = utf8.encode('renamed.txt');
    newPath = utf8.encode('replace.txt');
    bytes.setAll(oldPathPtr, oldPath);
    bytes.setAll(newPathPtr, newPath);
    expect(
      pathRename.ref([
        3,
        oldPathPtr,
        oldPath.length,
        3,
        newPathPtr,
        newPath.length,
      ]),
      0,
    );
    expect(File('${temp.path}/renamed.txt').existsSync(), isFalse);
    expect(File('${temp.path}/replace.txt').readAsStringSync(), 'source');

    oldPath = utf8.encode('dir-source');
    newPath = utf8.encode('dir-renamed');
    bytes.setAll(oldPathPtr, oldPath);
    bytes.setAll(newPathPtr, newPath);
    expect(
      pathRename.ref([
        3,
        oldPathPtr,
        oldPath.length,
        3,
        newPathPtr,
        newPath.length,
      ]),
      0,
    );
    expect(Directory('${temp.path}/dir-source').existsSync(), isFalse);
    expect(
      File('${temp.path}/dir-renamed/child.txt').readAsStringSync(),
      'child',
    );

    oldPath = utf8.encode('dir-renamed');
    newPath = utf8.encode('dir-target');
    bytes.setAll(oldPathPtr, oldPath);
    bytes.setAll(newPathPtr, newPath);
    expect(
      pathRename.ref([
        3,
        oldPathPtr,
        oldPath.length,
        3,
        newPathPtr,
        newPath.length,
      ]),
      0,
    );
    expect(Directory('${temp.path}/dir-renamed').existsSync(), isFalse);
    expect(
      File('${temp.path}/dir-target/child.txt').readAsStringSync(),
      'child',
    );

    oldPath = utf8.encode('dir-target');
    newPath = utf8.encode('non-empty-target');
    bytes.setAll(oldPathPtr, oldPath);
    bytes.setAll(newPathPtr, newPath);
    expect(
      pathRename.ref([
        3,
        oldPathPtr,
        oldPath.length,
        3,
        newPathPtr,
        newPath.length,
      ]),
      _errnoNotempty,
    );
    expect(Directory('${temp.path}/dir-target').existsSync(), isTrue);
    expect(Directory('${temp.path}/non-empty-target').existsSync(), isTrue);

    oldPath = utf8.encode('.');
    newPath = utf8.encode('moved-root');
    bytes.setAll(oldPathPtr, oldPath);
    bytes.setAll(newPathPtr, newPath);
    expect(
      pathRename.ref([
        3,
        oldPathPtr,
        oldPath.length,
        3,
        newPathPtr,
        newPath.length,
      ]),
      _errnoInval,
    );
    expect(Directory(temp.path).existsSync(), isTrue);

    oldPath = utf8.encode('missing.txt');
    newPath = utf8.encode('still-missing.txt');
    bytes.setAll(oldPathPtr, oldPath);
    bytes.setAll(newPathPtr, newPath);
    expect(
      pathRename.ref([
        3,
        oldPathPtr,
        oldPath.length,
        3,
        newPathPtr,
        newPath.length,
      ]),
      _errnoNoent,
    );
  });

  test('native root preopens map host filesystem children', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_root_host_fs_');
    addTearDown(() => temp.delete(recursive: true));
    File('${temp.path}/root.txt').writeAsStringSync('root-backed');

    final wasi = WASI(preopens: {'/': temp.path});
    final result = await WebAssembly.instantiate(
      wasiStartModuleBytes().buffer,
      wasi.imports,
    );
    final instance = result.instance;
    final preview1 = wasi.imports['wasi_snapshot_preview1']!;
    final pathOpen = preview1['path_open'] as FunctionImportExportValue;
    final fdClose = preview1['fd_close'] as FunctionImportExportValue;
    final memory = (instance.exports['memory'] as MemoryImportExportValue).ref;
    wasi.finalizeBindings(instance, memory: memory);

    final bytes = Uint8List.view(memory.buffer);
    final data = ByteData.view(memory.buffer);
    final path = utf8.encode('root.txt');
    const pathPtr = 1024;
    const openedFdPtr = 1056;
    bytes.setAll(pathPtr, path);

    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        path.length,
        0,
        _rightFdRead,
        0,
        0,
        openedFdPtr,
      ]),
      0,
    );
    expect(fdClose.ref([data.getUint32(openedFdPtr, Endian.little)]), 0);
  });

  test('native path_filestat_get reports host filesystem metadata', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_host_stat_');
    addTearDown(() => temp.delete(recursive: true));
    File('${temp.path}/data.txt').writeAsStringSync('metadata');
    Directory('${temp.path}/assets').createSync();

    final wasi = WASI(preopens: {'/host': temp.path});
    final result = await WebAssembly.instantiate(
      wasiStartModuleBytes().buffer,
      wasi.imports,
    );
    final instance = result.instance;
    final preview1 = wasi.imports['wasi_snapshot_preview1']!;
    final pathFilestatGet =
        preview1['path_filestat_get'] as FunctionImportExportValue;
    final memory = (instance.exports['memory'] as MemoryImportExportValue).ref;
    wasi.finalizeBindings(instance, memory: memory);

    final bytes = Uint8List.view(memory.buffer);
    final data = ByteData.view(memory.buffer);
    const pathPtr = 1024;
    const filestatPtr = 1088;

    final filePath = utf8.encode('data.txt');
    bytes.setAll(pathPtr, filePath);
    expect(
      pathFilestatGet.ref([3, 0, pathPtr, filePath.length, filestatPtr]),
      0,
    );
    expect(bytes[filestatPtr + _filestatFiletypeOffset], _filetypeRegularFile);
    expect(
      data.getUint64(filestatPtr + _filestatSizeOffset, Endian.little),
      'metadata'.length,
    );

    final directoryPath = utf8.encode('assets');
    bytes.setAll(pathPtr, directoryPath);
    expect(
      pathFilestatGet.ref([3, 0, pathPtr, directoryPath.length, filestatPtr]),
      0,
    );
    expect(bytes[filestatPtr + _filestatFiletypeOffset], _filetypeDirectory);

    final missingPath = utf8.encode('missing.txt');
    bytes.setAll(pathPtr, missingPath);
    expect(
      pathFilestatGet.ref([3, 0, pathPtr, missingPath.length, filestatPtr]),
      _errnoNoent,
    );
  });

  test('native fd_readdir lists host directory entries', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_host_readdir_');
    addTearDown(() => temp.delete(recursive: true));
    final assets = Directory('${temp.path}/assets')..createSync();
    File('${assets.path}/b.txt').writeAsStringSync('b');
    File('${assets.path}/a.txt').writeAsStringSync('a');
    Directory('${assets.path}/sub').createSync();

    final wasi = WASI(preopens: {'/host': temp.path});
    final result = await WebAssembly.instantiate(
      wasiStartModuleBytes().buffer,
      wasi.imports,
    );
    final instance = result.instance;
    final preview1 = wasi.imports['wasi_snapshot_preview1']!;
    final pathOpen = preview1['path_open'] as FunctionImportExportValue;
    final fdReaddir = preview1['fd_readdir'] as FunctionImportExportValue;
    final fdClose = preview1['fd_close'] as FunctionImportExportValue;
    final memory = (instance.exports['memory'] as MemoryImportExportValue).ref;
    wasi.finalizeBindings(instance, memory: memory);

    final bytes = Uint8List.view(memory.buffer);
    final data = ByteData.view(memory.buffer);
    final path = utf8.encode('assets');
    const pathPtr = 1024;
    const openedFdPtr = 1056;
    const direntsPtr = 1088;
    const bufusedPtr = 1408;
    bytes.setAll(pathPtr, path);

    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        path.length,
        _oflagDirectory,
        _rightFdReaddir,
        0,
        0,
        openedFdPtr,
      ]),
      0,
    );
    final dirFd = data.getUint32(openedFdPtr, Endian.little);

    expect(fdReaddir.ref([dirFd, direntsPtr, 256, 0, bufusedPtr]), 0);
    final bufused = data.getUint32(bufusedPtr, Endian.little);
    final entries = _readDirents(bytes, data, direntsPtr, bufused);
    expect(entries.map((entry) => entry.name).toList(), [
      'a.txt',
      'b.txt',
      'sub',
    ]);
    expect(entries.map((entry) => entry.type).toList(), [
      _filetypeRegularFile,
      _filetypeRegularFile,
      _filetypeDirectory,
    ]);
    expect(entries.map((entry) => entry.next).toList(), [1, 2, 3]);

    expect(fdClose.ref([dirFd]), 0);
  });
}
