import 'dart:io';

import 'package:listenbox_cli/listenbox_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runListenbox(arguments, debugProfile: true);
}
