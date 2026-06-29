final class NodeHostTemp {
  const NodeHostTemp(this.path);

  final String path;

  void writeFile(String relativePath, String content) {}

  void createDirectory(String relativePath) {}

  String readFile(String relativePath) => '';

  bool fileExists(String relativePath) => false;

  bool directoryExists(String relativePath) => false;

  bool symlinkExists(String relativePath) => false;

  String readLink(String relativePath) => '';

  void delete() {}
}

NodeHostTemp? createNodeHostTemp(String prefix) => null;
