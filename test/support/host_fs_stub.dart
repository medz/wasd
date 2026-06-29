final class HostTemp {
  const HostTemp(this.path);

  final String path;

  void writeFile(String relativePath, String content) {}

  String readFile(String relativePath) => '';

  void delete() {}
}

HostTemp? createHostTemp(String prefix) => null;
