import 'wasi_filesystem.dart';

WasiFileSystem createAutoWasiFileSystem({String? ioRootPath}) {
  return WasiInMemoryFileSystem();
}

const bool autoHostIoSupported = false;
