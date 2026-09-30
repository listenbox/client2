import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

/// Builds the vendored YouTube.js source with pinned, standalone esbuild.
/// All downloaded archives are verified before any file is extracted.
Future<File> bundleYoutubeJs(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  final manifestUri = input.packageRoot.resolve('youtubejs_tools.json');
  output.dependencies.add(manifestUri);
  final manifest = jsonDecode(
    await File.fromUri(manifestUri).readAsString(),
  ) as Map<String, dynamic>;
  final sourceRoot = Directory.fromUri(
    input.packageRoot.resolve('../../vendor/youtubejs/'),
  );
  if (!await Directory('${sourceRoot.path}/src').exists()) {
    throw StateError(
      'YouTube.js source is missing. Initialize vendor/youtubejs with '
      '`git submodule update --init --recursive` before building.',
    );
  }
  await _trackSourceTree(Directory('${sourceRoot.path}/src'), output);
  await _trackSourceTree(
    Directory('${sourceRoot.path}/protos/generated'),
    output,
  );
  output.dependencies.add(sourceRoot.uri.resolve('package.json'));
  output.dependencies.add(sourceRoot.uri.resolve('tsconfig.json'));
  final revision = await Process.run('git', [
    '-C',
    sourceRoot.path,
    'rev-parse',
    'HEAD',
  ]);
  if (revision.exitCode != 0 ||
      (revision.stdout as String).trim() != manifest['youtubejsRevision']) {
    throw StateError(
      'vendor/youtubejs must be checked out at the revision in '
      'youtubejs_tools.json. Update the submodule pin and tool manifest '
      'together when upgrading YouTube.js.',
    );
  }

  final host = switch (Abi.current()) {
    Abi.macosArm64 => 'macos-arm64',
    Abi.macosX64 => 'macos-x64',
    Abi.linuxX64 => 'linux-x64',
    Abi.windowsArm64 => 'windows-arm64',
    Abi.windowsX64 => 'windows-x64',
    final abi => throw UnsupportedError('No pinned esbuild for $abi'),
  };
  final esbuildVersion = manifest['esbuildVersion'] as String;
  final esbuild =
      (manifest['esbuild'] as Map<String, dynamic>)[host]
          as Map<String, dynamic>;
  final scratch = Directory.fromUri(
    input.outputDirectory.resolve('youtubejs/'),
  );
  if (await scratch.exists()) await scratch.delete(recursive: true);
  await scratch.create(recursive: true);
  final copiedSource = Directory('${scratch.path}/source');
  await _copyDirectory(
    Directory('${sourceRoot.path}/src'),
    Directory('${copiedSource.path}/src'),
  );
  await _copyDirectory(
    Directory('${sourceRoot.path}/protos/generated'),
    Directory('${copiedSource.path}/protos/generated'),
  );
  for (final name in ['package.json', 'tsconfig.json']) {
    await File('${sourceRoot.path}/$name').copy('${copiedSource.path}/$name');
  }

  final shared = Directory.fromUri(
    input.outputDirectoryShared.resolve('youtubejs-tools/'),
  );
  await shared.create(recursive: true);
  final esbuildDirectory = Directory('${scratch.path}/esbuild');
  await _extractPackage(
    await _verifiedArchive(
      shared,
      esbuild['package'] as String,
      esbuildVersion,
      esbuild['integrity'] as String,
    ),
    esbuildDirectory,
  );
  final executable = File(
    '${esbuildDirectory.path}/${esbuild['binary'] as String}',
  );
  if (!await executable.exists()) {
    throw StateError('Pinned esbuild archive has no ${esbuild['binary']}');
  }
  if (!Platform.isWindows) {
    final chmod = await Process.run('chmod', ['+x', executable.path]);
    if (chmod.exitCode != 0) {
      throw ProcessException(
        'chmod',
        ['+x', executable.path],
        '${chmod.stderr}',
        chmod.exitCode,
      );
    }
  }

  final nodeModules = Directory('${scratch.path}/node_modules');
  for (final dependency in manifest['dependencies'] as List<dynamic>) {
    final item = dependency as Map<String, dynamic>;
    final name = item['package'] as String;
    await _extractPackage(
      await _verifiedArchive(
        shared,
        name,
        item['version'] as String,
        item['integrity'] as String,
      ),
      Directory('${nodeModules.path}/$name'),
    );
  }
  final bundle = File('${scratch.path}/cf-worker.js');
  final arguments = [
    'src/platform/cf-worker.ts',
    '--bundle',
    '--target=es2020',
    '--keep-names',
    '--minify',
    '--format=esm',
    '--define:global=globalThis',
    '--conditions=module',
    '--platform=node',
    '--outfile=${bundle.path}',
  ];
  final result = await Process.run(
    executable.path,
    arguments,
    workingDirectory: copiedSource.path,
    environment: {'NODE_PATH': nodeModules.path},
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable.path,
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  return bundle;
}

/// Emits only a byte container. Application behavior stays in Dart/YouTube.js.
Future<File> writeYoutubeJsResourceSource(
  File bundle,
  Uri outputDirectory,
) async {
  final source = File.fromUri(outputDirectory.resolve('youtubejs_resource.rs'));
  final text = StringBuffer()
    ..writeln(
      'static YOUTUBEJS_SOURCE: &[u8] = include_bytes!(${jsonEncode(bundle.path)});',
    )
    ..writeln('#[no_mangle]')
    ..writeln('pub extern "C" fn listenbox_youtubejs_data() -> *const u8 {')
    ..writeln('    YOUTUBEJS_SOURCE.as_ptr()')
    ..writeln('}')
    ..writeln('#[no_mangle]')
    ..writeln('pub extern "C" fn listenbox_youtubejs_length() -> usize {')
    ..writeln('    YOUTUBEJS_SOURCE.len()')
    ..writeln('}');
  final contents = text.toString();
  if (!await source.exists() || await source.readAsString() != contents) {
    await source.writeAsString(contents);
  }
  return source;
}

Future<void> _trackSourceTree(
  Directory directory,
  BuildOutputBuilder output,
) async {
  output.dependencies.add(directory.uri);
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is Link) {
      throw StateError(
        'Unexpected symlink in vendored YouTube.js: ${entity.path}',
      );
    }
    output.dependencies.add(entity.uri);
  }
}

Future<void> _copyDirectory(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(source.path.length + 1);
    final destination = '${target.path}/$relative';
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
    } else {
      throw StateError(
        'Unexpected symlink in vendored YouTube.js: ${entity.path}',
      );
    }
  }
}

Future<Uint8List> _verifiedArchive(
  Directory shared,
  String name,
  String version,
  String integrity,
) async {
  final archiveFile = File(
    '${shared.path}/${name.replaceAll('/', '_').replaceAll('@', '')}-$version.tgz',
  );
  final expected = integrity.replaceFirst('sha512-', '');
  if (!integrity.startsWith('sha512-')) {
    throw FormatException('Expected SHA-512 npm integrity for $name');
  }
  if (await archiveFile.exists()) {
    final cached = await archiveFile.readAsBytes();
    if (base64Encode(sha512.convert(cached).bytes) == expected) return cached;
    throw StateError(
      'Cached npm archive has the wrong SHA-512: ${archiveFile.path}',
    );
  }
  final basename = name.split('/').last;
  final url = Uri.parse(
    'https://registry.npmjs.org/${Uri.encodeComponent(name)}/-/$basename-$version.tgz',
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Pinned npm archive download failed: ${response.statusCode}',
        uri: url,
      );
    }
    final data = BytesBuilder(copy: false);
    await for (final chunk in response) {
      data.add(chunk);
    }
    final bytes = data.takeBytes();
    if (base64Encode(sha512.convert(bytes).bytes) != expected) {
      throw StateError('Downloaded npm archive has the wrong SHA-512: $url');
    }
    final partial = File('${archiveFile.path}.${pid}.partial');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(archiveFile.path);
    } on FileSystemException {
      if (!await archiveFile.exists()) rethrow;
      final winner = await archiveFile.readAsBytes();
      if (base64Encode(sha512.convert(winner).bytes) != expected) rethrow;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

Future<void> _extractPackage(Uint8List archiveBytes, Directory target) async {
  await target.create(recursive: true);
  final tar = TarDecoder().decodeBytes(
    GZipDecoder().decodeBytes(archiveBytes, verify: true),
    verify: true,
  );
  for (final entry in tar) {
    if (!entry.name.startsWith('package/') || entry.isSymbolicLink) {
      throw FormatException('Unexpected npm archive entry: ${entry.name}');
    }
    final relative = entry.name.substring('package/'.length);
    if (relative.isEmpty) continue;
    final segments = relative.split('/');
    if (segments.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains('\\'),
    )) {
      throw FormatException('Unsafe npm archive entry: ${entry.name}');
    }
    final destination = File('${target.path}/$relative');
    if (entry.isDirectory) {
      await Directory(destination.path).create(recursive: true);
    } else if (entry.isFile) {
      await destination.parent.create(recursive: true);
      await destination.writeAsBytes(entry.content);
    }
  }
}
