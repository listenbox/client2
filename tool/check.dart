import 'dart:io';

import 'design.dart' as design;

Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent.path;
  await design.main(['--check']);
  if (exitCode != 0) exit(exitCode);
  for (final file in Directory(
    '$root/packages/desktop/lib',
  ).listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart') ||
        file.path.endsWith('/design_tokens.dart'))
      continue;
    final source = file.readAsStringSync();
    if (RegExp(
      r'\b(?:Color|ColorSwatch|MaterialColor|MaterialAccentColor)\s*(?:\(|\.from)|\bColors\.|ColorScheme\.fromSeed|fontSize:\s*[\d.]|FontWeight\.|(?:BorderRadius|Radius)\.circular\(\s*\d',
    ).hasMatch(source)) {
      stderr.writeln(
        'Raw design value in ${file.path}. Use design_tokens.dart and ListenboxTheme.',
      );
      exit(1);
    }
  }
  for (final arguments in [
    ['format', '--output=none', '--set-exit-if-changed', 'tool', 'packages'],
    ['analyze', '--fatal-infos'],
  ]) {
    final process = await Process.start(
      Platform.resolvedExecutable,
      arguments,
      workingDirectory: root,
      mode: ProcessStartMode.inheritStdio,
    );
    final result = await process.exitCode;
    if (result != 0) exit(result);
  }
}
