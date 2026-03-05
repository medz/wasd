import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('README test commands reference existing files', () {
    final readme = File('README.md').readAsStringSync();
    final commandPattern = RegExp(
      r'^dart test (test/[^\n]+)$',
      multiLine: true,
    );

    for (final match in commandPattern.allMatches(readme)) {
      final args = match.group(1)!.split(RegExp(r'\s+'));
      for (final path in args.where((entry) => entry.startsWith('test/'))) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: 'README references missing test file: $path',
        );
      }
    }
  });
}
