export 'host_fs_stub.dart'
    if (dart.library.io) 'host_fs_io.dart'
    if (dart.library.js_interop) 'host_fs_js.dart';
