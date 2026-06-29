final class HostTemp {
  const HostTemp(this.path);

  final String path;

  void writeFile(String relativePath, String content) {}

  void createDirectory(String relativePath) {}

  String readFile(String relativePath) => '';

  ({int accessTimeNanos, int modificationTimeNanos}) fileTimes(
    String relativePath,
  ) => (accessTimeNanos: 0, modificationTimeNanos: 0);

  ({int accessTimeNanos, int modificationTimeNanos}) directoryTimes(
    String relativePath,
  ) => (accessTimeNanos: 0, modificationTimeNanos: 0);

  bool fileExists(String relativePath) => false;

  bool directoryExists(String relativePath) => false;

  bool symlinkExists(String relativePath) => false;

  String readLink(String relativePath) => '';

  void createSymlink(String target, String relativePath) {}

  void delete() {}
}

HostTemp? createHostTemp(String prefix) => null;
