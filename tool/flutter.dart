import 'dart:io';

Future<void> main(List<String> arguments) async {
  exitCode = await runFlutter(arguments);
}

/// Preserve Flutter's terminal, hot reload, and exit status. Select full Xcode
/// for this child process when macOS only selected Command Line Tools.
Future<int> runFlutter(
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final environment = <String, String>{};
  if (Platform.isMacOS && !Platform.environment.containsKey('DEVELOPER_DIR')) {
    final selection = await Process.run('/usr/bin/xcode-select', [
      '--print-path',
    ]);
    final selected = (selection.stdout as String).trim();
    if (selection.exitCode != 0 ||
        !await File('$selected/usr/bin/xcodebuild').exists()) {
      const installed = '/Applications/Xcode.app/Contents/Developer';
      if (await File('$installed/usr/bin/xcodebuild').exists()) {
        environment['DEVELOPER_DIR'] = installed;
      }
    }
  }
  final process = await Process.start(
    Platform.isWindows ? 'flutter.bat' : 'flutter',
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: Platform.isWindows,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}
