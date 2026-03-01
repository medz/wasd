import 'package:test/test.dart';
import 'package:wasd/src/testing/threads_portable.dart';

void main() {
  test('threads portable checks pass', () {
    expect(runThreadsPortableChecks, returnsNormally);
  });
}
