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
const int _rightFdReaddir = 1 << 14;
const int _rightFdFilestatGet = 1 << 21;
const int _errnoNoent = 44;
const int _errnoNotcapable = 76;
const int _filestatFiletypeOffset = 16;
const int _filestatSizeOffset = 32;
const int _filetypeDirectory = 3;
const int _filetypeRegularFile = 4;
const int _oflagDirectory = 2;
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

    expect(
      pathOpen.ref([
        3,
        0,
        pathPtr,
        path.length,
        0,
        _rightFdWrite,
        0,
        0,
        openedFdPtr,
      ]),
      _errnoNotcapable,
    );

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
