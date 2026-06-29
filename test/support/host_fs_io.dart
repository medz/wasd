import 'dart:io' as io;

final class HostTemp {
  HostTemp._(this.path);

  final String path;

  void writeFile(String relativePath, String content) {
    final file = io.File(_join(relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void createDirectory(String relativePath) {
    io.Directory(_join(relativePath)).createSync(recursive: true);
  }

  String readFile(String relativePath) =>
      io.File(_join(relativePath)).readAsStringSync();

  ({int accessTimeNanos, int modificationTimeNanos}) fileTimes(
    String relativePath,
  ) {
    final stat = io.File(_join(relativePath)).statSync();
    return _timesFromStat(stat);
  }

  ({int accessTimeNanos, int modificationTimeNanos}) directoryTimes(
    String relativePath,
  ) {
    final stat = io.Directory(_join(relativePath)).statSync();
    return _timesFromStat(stat);
  }

  bool fileExists(String relativePath) =>
      io.FileSystemEntity.typeSync(_join(relativePath), followLinks: false) ==
      io.FileSystemEntityType.file;

  bool directoryExists(String relativePath) =>
      io.FileSystemEntity.typeSync(_join(relativePath), followLinks: false) ==
      io.FileSystemEntityType.directory;

  bool symlinkExists(String relativePath) =>
      io.FileSystemEntity.typeSync(_join(relativePath), followLinks: false) ==
      io.FileSystemEntityType.link;

  String readLink(String relativePath) =>
      io.Link(_join(relativePath)).targetSync();

  void createSymlink(String target, String relativePath) {
    final link = io.Link(_join(relativePath));
    link.parent.createSync(recursive: true);
    link.createSync(target);
  }

  void delete() {
    io.Directory(path).deleteSync(recursive: true);
  }

  ({int accessTimeNanos, int modificationTimeNanos}) _timesFromStat(
    io.FileStat stat,
  ) => (
    accessTimeNanos: stat.accessed.microsecondsSinceEpoch * 1000,
    modificationTimeNanos: stat.modified.microsecondsSinceEpoch * 1000,
  );

  String _join(String relativePath) =>
      '$path${io.Platform.pathSeparator}$relativePath';
}

HostTemp? createHostTemp(String prefix) =>
    HostTemp._(io.Directory.systemTemp.createTempSync(prefix).path);
