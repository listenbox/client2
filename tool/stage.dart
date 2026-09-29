import 'dart:io';

import 'build.dart' show copyDirectory, root;

/// Copies the CLI bundle, including code assets, into API E2E's sandbox.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Expected a destination directory');
  }
  final source = Directory('${root.path}/packages/cli/dist/e2e/bundle');
  if (!await source.exists()) throw StateError('Build missing: ${source.path}');
  final target = Directory(arguments.single).absolute;
  if (await target.exists()) await target.delete(recursive: true);
  await copyDirectory(source, target);
}
