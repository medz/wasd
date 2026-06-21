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
const int filetypeSymbolicLink = 7;
const int lookupflagSymlinkFollow = 1;
const int fdflagAppend = 1;
const int fdflagDsync = 2;
const int fdflagNonblock = 4;
const int fdflagRsync = 8;
const int fdflagSync = 16;
const int fdflagKnownMask =
    fdflagAppend | fdflagDsync | fdflagNonblock | fdflagRsync | fdflagSync;

/// Preview1 imports that should exist and return `ENOSYS` when unsupported.
const List<String> preview1NosysImports = <String>[
  'fd_fdstat_set_rights',
  'fd_renumber',
  'proc_raise',
  'sock_accept',
  'sock_recv',
  'sock_send',
  'sock_shutdown',
];
