import 'dart:io' as io;

final class HostTemp {
  HostTemp._(this.path);

  final String path;

  void writeFile(String relativePath, String content) {
    final file = io.File(_join(relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String readFile(String relativePath) =>
      io.File(_join(relativePath)).readAsStringSync();

  void delete() {
    io.Directory(path).deleteSync(recursive: true);
  }

  String _join(String relativePath) =>
      '$path${io.Platform.pathSeparator}$relativePath';
}

HostTemp? createHostTemp(String prefix) =>
    HostTemp._(io.Directory.systemTemp.createTempSync(prefix).path);
