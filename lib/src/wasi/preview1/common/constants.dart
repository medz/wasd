/// Shared WASI preview1 constants for minimal host implementations.
const int iovecEntrySize = 8;
const int errnoSuccess = 0;
const int errnoInval = 28;
const int errnoBadf = 8;
const int errnoNoent = 44;
const int errnoNosys = 52;
const int prestatSize = 8;
const int preopenTypeDir = 0;
const int fdstatSize = 24;
const int filetypeCharacterDevice = 2;
const int filetypeDirectory = 3;
const int filetypeRegularFile = 4;

/// Preview1 imports that should exist and return `ENOSYS` when unsupported.
const List<String> preview1NosysImports = <String>[
  'clock_res_get',
  'fd_advise',
  'fd_allocate',
  'fd_datasync',
  'fd_fdstat_set_flags',
  'fd_fdstat_set_rights',
  'fd_filestat_get',
  'fd_filestat_set_size',
  'fd_filestat_set_times',
  'fd_pread',
  'fd_pwrite',
  'fd_readdir',
  'fd_renumber',
  'fd_seek',
  'fd_sync',
  'fd_tell',
  'path_create_directory',
  'path_filestat_get',
  'path_filestat_set_times',
  'path_link',
  'path_readlink',
  'path_remove_directory',
  'path_rename',
  'path_symlink',
  'path_unlink_file',
  'proc_raise',
  'sock_accept',
  'sock_recv',
  'sock_send',
  'sock_shutdown',
];
