import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('README test commands reference existing files', () {
    final readme = File('README.md').readAsStringSync();
    final commandPattern = RegExp(
      r'^dart test (test/[^\n]+)$',
      multiLine: true,
    );
    final matches = commandPattern.allMatches(readme).toList();

    expect(
      matches,
      isNotEmpty,
      reason: 'README should include at least one dart test command.',
    );

    for (final match in matches) {
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

  test('README example run commands reference existing Dart files', () {
    final readme = File('README.md').readAsStringSync();
    final commandPattern = RegExp(
      r'^dart run (example/[^\s`]+\.dart)(?:\s+.*)?$',
      multiLine: true,
    );
    final matches = commandPattern.allMatches(readme).toList();

    expect(
      matches,
      isNotEmpty,
      reason: 'README should include at least one dart run example command.',
    );

    for (final match in matches) {
      final path = match.group(1)!;
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'README references missing example file: $path',
      );
    }
  });
}
