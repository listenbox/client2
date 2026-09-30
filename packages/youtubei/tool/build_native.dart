// Deliberate release-only FJS artifact builder. Never call this from a package
// hook, Moon prerequisite, or normal CI build.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const archiveUrl = 'https://pub.dev/api/archives/fjs-3.3.0.tar.gz';
const archiveSha256 =
    'cd1a9e36dac80966bafcc222461b7ab314eda2160567429c9ac6c4d3120d93bc';
const targets = <String, String>{
  'macos-arm64': 'aarch64-apple-darwin',
  'macos-x64': 'x86_64-apple-darwin',
  'linux-x64': 'x86_64-unknown-linux-gnu',
  'windows-x64': 'x86_64-pc-windows-msvc',
  'windows-arm64': 'aarch64-pc-windows-msvc',
};

Future<void> main(List<String> args) async {
  if (args.length != 2 || !targets.containsKey(args.first)) {
    stderr.writeln(
      'Usage: dart run tool/build_native.dart <${targets.keys.join('|')}> <output-directory>',
    );
    exitCode = 2;
    return;
  }
  final target = args.first;
  final triple = targets[target]!;
  final output = Directory(args[1]).absolute;
  await output.create(recursive: true);
  final work = await Directory.systemTemp.createTemp('client-youtubei-fjs-');
  try {
    final archive = File(
      '${work.path}${Platform.pathSeparator}fjs-3.3.0.tar.gz',
    );
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(archiveUrl)))
          .close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('FJS source returned ${response.statusCode}');
      }
      final sink = archive.openWrite();
      await sink.addStream(response);
      await sink.close();
    } finally {
      client.close(force: true);
    }
    if (await _hash(archive) != archiveSha256) {
      throw StateError('FJS source archive SHA-256 mismatch');
    }
    final source = Directory('${work.path}${Platform.pathSeparator}source');
    await source.create();
    await _run('tar', ['-xzf', archive.path, '-C', source.path]);
    await _run('rustup', ['target', 'add', triple]);
    await _run('cargo', [
      'build',
      '--manifest-path',
      '${source.path}${Platform.pathSeparator}libfjs${Platform.pathSeparator}Cargo.toml',
      '--release',
      '--locked',
      '--target',
      triple,
    ]);
    final extension = target.startsWith('windows')
        ? 'dll'
        : target.startsWith('macos')
        ? 'dylib'
        : 'so';
    final filename = target.startsWith('windows')
        ? 'fjs.$extension'
        : 'libfjs.$extension';
    final built = File(
      '${source.path}${Platform.pathSeparator}libfjs${Platform.pathSeparator}target${Platform.pathSeparator}$triple${Platform.pathSeparator}release${Platform.pathSeparator}$filename',
    );
    if (!await built.exists())
      throw StateError('Cargo produced no $filename for $target');
    final artifact = await built.copy(
      '${output.path}${Platform.pathSeparator}$filename',
    );
    final digest = await _hash(artifact);
    stdout.writeln(
      jsonEncode({
        'target': target,
        'source': archiveUrl,
        'sourceSha256': archiveSha256,
        'rustTarget': triple,
        'filename': filename,
        'sha256': digest,
      }),
    );
  } finally {
    await work.delete(recursive: true);
  }
}

Future<void> _run(String executable, List<String> arguments) async {
  final process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
  );
  final status = await process.exitCode;
  if (status != 0)
    throw ProcessException(executable, arguments, 'Exited $status', status);
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
