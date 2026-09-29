import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

import '../tool/bundle_youtubejs.dart';

/// Registers pinned FJS binaries and embeds vendored YouTube.js in a tiny
/// generated resource library. FJS itself is never compiled by normal builds.
Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final manifestUri = input.packageRoot.resolve('native_artifacts.json');
    output.dependencies.add(manifestUri);
    final manifest = jsonDecode(
      await File.fromUri(manifestUri).readAsString(),
    ) as Map<String, dynamic>;
    final targets = manifest['targets'] as Map<String, dynamic>;
    final target =
        '${input.config.code.targetOS.name}-${input.config.code.targetArchitecture.name}';
    final descriptor = targets[target];
    if (descriptor is! Map<String, dynamic>) {
      throw UnsupportedError(
        'No FJS 3.3.0 native artifact is published for $target. '
        'Publish one from the pinned FJS source before building this target.',
      );
    }
    final url = Uri.parse(descriptor['url'] as String);
    final expected = descriptor['sha256'] as String;
    final filename = descriptor['filename'] as String;
    final artifact = File.fromUri(
      input.outputDirectoryShared.resolve('$target/$filename'),
    );
    await artifact.parent.create(recursive: true);
    if (await artifact.exists()) {
      if (await _hash(artifact) != expected) {
        throw StateError(
          'Cached FJS artifact has the wrong SHA-256: ${artifact.path}',
        );
      }
    } else {
      final temporary = File('${artifact.path}.partial');
      final client = HttpClient();
      try {
        final request = await client.getUrl(url);
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException(
            'FJS artifact download failed: ${response.statusCode}',
            uri: url,
          );
        }
        final sink = temporary.openWrite();
        await sink.addStream(response);
        await sink.close();
        if (await _hash(temporary) != expected) {
          throw StateError(
            'Downloaded FJS artifact has the wrong SHA-256: $url',
          );
        }
        await temporary.rename(artifact.path);
      } finally {
        client.close(force: true);
        if (await temporary.exists()) await temporary.delete();
      }
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'libfjs',
        linkMode: DynamicLoadingBundled(),
        file: artifact.uri,
      ),
    );

    final bundle = await bundleYoutubeJs(input, output);
    final resourceSource = await writeYoutubeJsResourceSource(
      bundle,
      input.outputDirectory,
    );
    final rustToolchain = input.packageRoot.resolve(
      '../../rust-toolchain.toml',
    );
    output.dependencies.add(rustToolchain);
    if (!await File.fromUri(rustToolchain).exists()) {
      throw StateError(
        'The pinned client Rust toolchain is missing: $rustToolchain',
      );
    }
    final triple = switch (target) {
      'macos-arm64' => 'aarch64-apple-darwin',
      'macos-x64' => 'x86_64-apple-darwin',
      'linux-x64' => 'x86_64-unknown-linux-gnu',
      'windows-arm64' => 'aarch64-pc-windows-msvc',
      'windows-x64' => 'x86_64-pc-windows-msvc',
      _ => throw UnsupportedError('No Rust resource target for $target'),
    };
    final clientRoot = Directory.fromUri(input.packageRoot.resolve('../../'));
    final kacheConfig = File.fromUri(clientRoot.uri.resolve('.kache.toml'));
    output.dependencies.add(kacheConfig.uri);
    if (!await kacheConfig.exists()) {
      throw StateError(
        'The client Kache config is missing: ${kacheConfig.path}',
      );
    }
    final selectedRustc = await Process.run('rustup', [
      'which',
      'rustc',
    ], workingDirectory: clientRoot.path);
    if (selectedRustc.exitCode != 0) {
      throw ProcessException(
        'rustup',
        ['which', 'rustc'],
        '${selectedRustc.stderr}',
        selectedRustc.exitCode,
      );
    }
    final rustc = (selectedRustc.stdout as String).trim();
    final installed = await Process.run('rustup', [
      'target',
      'list',
      '--installed',
    ], workingDirectory: clientRoot.path);
    if (installed.exitCode != 0) {
      throw ProcessException(
        'rustup',
        ['target', 'list', '--installed'],
        '${installed.stderr}',
        installed.exitCode,
      );
    }
    if (!(installed.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .contains(triple)) {
      final addTarget = await Process.run('rustup', [
        'target',
        'add',
        triple,
      ], workingDirectory: clientRoot.path);
      if (addTarget.exitCode != 0) {
        throw ProcessException(
          'rustup',
          ['target', 'add', triple],
          '${addTarget.stderr}',
          addTarget.exitCode,
        );
      }
    }
    final resourceFilename = switch (input.config.code.targetOS) {
      OS.macOS => 'libyoutubejs_resource.dylib',
      OS.linux => 'libyoutubejs_resource.so',
      OS.windows => 'youtubejs_resource.dll',
      final os => throw UnsupportedError('No Rust resource library for $os'),
    };
    final resource = File.fromUri(
      input.outputDirectory.resolve(resourceFilename),
    );
    final rustArgs = [
      '--crate-type=cdylib',
      '--edition=2021',
      '--target=$triple',
      '-C',
      'opt-level=z',
      '-C',
      'panic=abort',
      '-o',
      resource.path,
      resourceSource.path,
    ];
    late final ProcessResult compile;
    try {
      compile = await Process.run(
        'kache',
        [rustc, ...rustArgs],
        workingDirectory: clientRoot.path,
        environment: {'KACHE_CONFIG': kacheConfig.path},
      );
    } on ProcessException catch (error) {
      throw StateError(
        'Kache 0.27.0 is required to build the YouTube.js resource. '
        'Install its prebuilt executable for this host: $error',
      );
    }
    if (compile.exitCode != 0) {
      throw ProcessException(
        'kache',
        [rustc, ...rustArgs],
        '${compile.stdout}\n${compile.stderr}',
        compile.exitCode,
      );
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/youtubejs_asset.dart',
        linkMode: DynamicLoadingBundled(),
        file: resource.uri,
      ),
    );
  });
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
