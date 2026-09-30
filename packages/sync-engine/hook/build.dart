import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

import 'ffmpeg_artifacts.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final target =
        '${input.config.code.targetOS.name}-'
        '${input.config.code.targetArchitecture.name}';
    final artifact = ffmpegArtifacts[target];
    if (artifact == null) {
      throw UnsupportedError(
        'No pinned native FFmpegKit artifact for $target. '
        'Publish and pin a compatible native bundle before building this target.',
      );
    }
    output.dependencies.add(
      File.fromUri(input.packageRoot.resolve('hook/ffmpeg_artifacts.dart')).uri,
    );
    final cache = Directory.fromUri(
      input.outputDirectoryShared.resolve('ffmpegkit/'),
    );
    await cache.create(recursive: true);
    final archive = File.fromUri(cache.uri.resolve(artifact.sha256));
    await _verifiedArchive(archive, artifact);

    final bytes = await archive.readAsBytes();
    final zip = ZipDecoder().decodeBytes(bytes);
    final entry = zip.find(artifact.entry);
    if (entry == null || !entry.isFile || entry.size < 1000000) {
      throw StateError('Pinned FFmpegKit archive lacks ${artifact.entry}');
    }
    final outputPath = switch (input.config.code.targetOS) {
      OS.macOS => 'ffmpegkit.framework/Versions/A/ffmpegkit',
      OS.linux => 'libffmpegkit.so',
      OS.windows => 'libffmpegkit.dll',
      _ => throw UnsupportedError('Unsupported FFmpegKit target $target'),
    };
    final library = File.fromUri(input.outputDirectory.resolve(outputPath));
    await library.parent.create(recursive: true);
    await library.writeAsBytes(entry.readBytes()!, flush: true);
    await entry.close();
    if (input.config.code.targetOS == OS.macOS) {
      // Dart's native asset bundler rewrites a single Mach-O install name.
      // The pinned archive is universal, so select the requested target slice.
      final slice = input.config.code.targetArchitecture.name == 'arm64'
          ? 'arm64'
          : 'x86_64';
      final thinned = File('${library.path}.thin');
      final result = await Process.run('lipo', [
        library.path,
        '-thin',
        slice,
        '-output',
        thinned.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('Could not select FFmpegKit $slice: ${result.stderr}');
      }
      await thinned.rename(library.path);
      final framework = Directory.fromUri(
        input.outputDirectory.resolve('ffmpegkit.framework/'),
      );
      final current = Link.fromUri(framework.uri.resolve('Versions/Current'));
      final executable = Link.fromUri(framework.uri.resolve('ffmpegkit'));
      if (await current.exists()) await current.delete();
      if (await executable.exists()) await executable.delete();
      await current.create('A');
      await executable.create('Versions/Current/ffmpegkit');
      final plist = File.fromUri(
        framework.uri.resolve('Versions/A/Resources/Info.plist'),
      );
      await plist.parent.create(recursive: true);
      await plist.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ffmpegkit</string>
<key>CFBundleIdentifier</key><string>app.listenbox.ffmpegkit</string>
<key>CFBundlePackageType</key><string>FMWK</string>
</dict></plist>''');
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'ffmpegkit',
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );

    // The Windows ARM64 publication recipe places every non-system import
    // beside the main DLL. Register those files individually so Dart and
    // Flutter copy them next to libffmpegkit.dll, where the platform loader
    // resolves its imports. The pinned macOS, Linux, and Windows x64 archives
    // currently have no additional native libraries.
    final nativeLibraryName = RegExp(
      r'\.(?:dll|dylib|so(?:\.\d+)*)$',
      caseSensitive: false,
    );
    final directoryInArchive = artifact.entry.substring(
      0,
      artifact.entry.lastIndexOf('/') + 1,
    );
    final dependencies = zip.files.where(
      (candidate) =>
          candidate.isFile &&
          candidate.name != artifact.entry &&
          nativeLibraryName.hasMatch(candidate.name),
    );
    var dependencyIndex = 0;
    for (final dependency in dependencies) {
      if (!dependency.name.startsWith(directoryInArchive) ||
          dependency.name.substring(directoryInArchive.length).contains('/')) {
        throw StateError(
          'Pinned FFmpegKit archive has a native dependency outside '
          'the main library directory: ${dependency.name}',
        );
      }
      final name = dependency.name.substring(directoryInArchive.length);
      if (dependency.size == 0) {
        throw StateError('Pinned FFmpegKit dependency is empty: $name');
      }
      final file = File.fromUri(input.outputDirectory.resolve(name));
      await file.writeAsBytes(dependency.readBytes()!, flush: true);
      await dependency.close();
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'ffmpegkit-dependency-${dependencyIndex++}',
          linkMode: DynamicLoadingBundled(),
          file: file.uri,
        ),
      );
    }
  });
}

Future<void> _verifiedArchive(File archive, FfmpegArtifact artifact) async {
  if (await archive.exists()) {
    if (await _sha256(archive) == artifact.sha256) return;
    await archive.delete();
  }
  final partial = File('${archive.path}.partial');
  if (await partial.exists()) await partial.delete();
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(artifact.url));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'listenbox-client2-native-artifacts',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'FFmpegKit download returned ${response.statusCode}',
        uri: Uri.parse(artifact.url),
      );
    }
    final sink = partial.openWrite();
    await response.pipe(sink);
    await sink.close();
    final actual = await _sha256(partial);
    if (actual != artifact.sha256) {
      throw StateError(
        'FFmpegKit SHA-256 mismatch: expected ${artifact.sha256}, got $actual',
      );
    }
    await partial.rename(archive.path);
  } finally {
    client.close(force: true);
    if (await partial.exists()) await partial.delete();
  }
}

Future<String> _sha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
