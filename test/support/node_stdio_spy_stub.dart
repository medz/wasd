final class NodeStdioSpy {
  List<String> get stdout => const <String>[];

  List<String> get stderr => const <String>[];

  void restore() {}
}

NodeStdioSpy installNodeStdioSpy() {
  throw UnsupportedError('Node stdio spy is only available on Node.js.');
}
