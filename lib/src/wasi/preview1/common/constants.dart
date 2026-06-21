/// Shared WASI preview1 constants for minimal host implementations.
const int iovecEntrySize = 8;
const int errnoSuccess = 0;
const int errnoInval = 28;
const int errnoBadf = 8;
const int errnoExist = 20;
const int errnoIsdir = 31;
const int errnoNoent = 44;
const int errnoNosys = 52;
const int errnoNotdir = 54;
const int errnoNotempty = 55;
const int prestatSize = 8;
const int preopenTypeDir = 0;
const int fdstatSize = 24;
const int direntSize = 24;
const int direntNextOffset = 0;
const int direntInodeOffset = 8;
const int direntNameLengthOffset = 16;
const int direntTypeOffset = 20;
const int filetypeCharacterDevice = 2;
const int filetypeDirectory = 3;
const int filetypeRegularFile = 4;

/// Preview1 imports that should exist and return `ENOSYS` when unsupported.
const List<String> preview1NosysImports = <String>[
  'fd_advise',
  'fd_datasync',
  'fd_fdstat_set_flags',
  'fd_fdstat_set_rights',
  'fd_filestat_set_times',
  'fd_renumber',
  'fd_sync',
  'path_filestat_set_times',
  'path_link',
  'path_readlink',
  'path_symlink',
  'proc_raise',
  'sock_accept',
  'sock_recv',
  'sock_send',
  'sock_shutdown',
];
