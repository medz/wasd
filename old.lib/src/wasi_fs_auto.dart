import 'wasi_filesystem.dart';
import 'wasi_fs_auto_stub.dart'
    if (dart.library.io) 'wasi_fs_auto_io.dart'
    as auto;

WasiFileSystem createAutoWasiFileSystem({String? ioRootPath}) {
  return auto.createAutoWasiFileSystem(ioRootPath: ioRootPath);
}

bool get autoHostIoSupported => auto.autoHostIoSupported;
