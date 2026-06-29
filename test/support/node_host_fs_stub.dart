final class NodeHostTemp {
  const NodeHostTemp(this.path);

  final String path;

  void writeFile(String relativePath, String content) {}

  String readFile(String relativePath) => '';

  void delete() {}
}

NodeHostTemp? createNodeHostTemp(String prefix) => null;
