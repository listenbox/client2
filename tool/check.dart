import 'dart:io';

Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent.path;
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
