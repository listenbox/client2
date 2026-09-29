import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

final root = File.fromUri(Platform.script).parent.parent;
final executableSuffix = Platform.isWindows ? '.exe' : '';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Expected cli, cli-e2e, or desktop');
  }
  final target = arguments.single;
  final e2e = target.endsWith('-e2e');
  if (target == 'cli' || target == 'cli-e2e') {
    final directory = Directory('${root.path}/packages/cli');
    final output = e2e ? 'dist/e2e' : 'dist/release';
    await run(Platform.resolvedExecutable, [
      'build',
      'cli',
      '--target',
      e2e ? 'tool/listenbox_dev.dart' : 'bin/listenbox.dart',
      '--output',
      output,
    ], directory);
    if (e2e) {
      await File(
        '${directory.path}/$output/bundle/bin/listenbox_dev$executableSuffix',
      ).rename(
        '${directory.path}/$output/bundle/bin/listenbox$executableSuffix',
      );
    }
    final bundle = Directory('${directory.path}/$output/bundle');
    if (Platform.isWindows) {
      await bundleWindowsRuntime([
        Directory('${bundle.path}/bin'),
        Directory('${bundle.path}/lib'),
      ]);
    }
    await notices(bundle);
    return;
  }
  if (target != 'desktop') {
    throw ArgumentError.value(target, 'target', 'Unknown build');
  }
  final os = switch (Platform.operatingSystem) {
    'macos' => 'macos',
    'windows' => 'windows',
    'linux' => 'linux',
    final other => throw UnsupportedError('Desktop target $other'),
  };
  final architecture = switch (Abi.current()) {
    Abi.macosArm64 || Abi.windowsArm64 => 'arm64',
    Abi.macosX64 || Abi.windowsX64 || Abi.linuxX64 => 'x64',
    final other => throw UnsupportedError('Desktop architecture $other'),
  };
  final directory = Directory('${root.path}/packages/desktop');
  await run(Platform.isWindows ? 'flutter.bat' : 'flutter', [
    'build',
    os,
    '--release',
    '--no-pub',
    if (os == 'windows') '--target-platform=windows-$architecture',
    if (os == 'linux') '--target-platform=linux-$architecture',
  ], directory);
  final source = Directory(switch (os) {
    'macos' => '${directory.path}/build/macos/Build/Products/Release',
    'windows' => '${directory.path}/build/windows/$architecture/runner/Release',
    _ => '${directory.path}/build/linux/$architecture/release/bundle',
  });
  final output = Directory('${directory.path}/dist/release');
  if (await output.exists()) await output.delete(recursive: true);
  await output.create(recursive: true);
  if (os == 'macos') {
    final apps = await source
        .list()
        .where((entry) => entry.path.endsWith('.app'))
        .toList();
    if (apps.length != 1)
      throw StateError(
        'Expected one built macOS application in ${source.path}',
      );
    await copyDirectory(
      Directory(apps.single.path),
      Directory('${output.path}/Listenbox.app'),
    );
  } else {
    await copyDirectory(source, output);
  }
  if (os == 'windows') await bundleWindowsRuntime([output]);
  await notices(output);
}

Future<void> bundleWindowsRuntime(List<Directory> destinations) async {
  final architecture = switch (Abi.current()) {
    Abi.windowsX64 => 'x64',
    Abi.windowsArm64 => 'arm64',
    final abi => throw UnsupportedError('Windows runtime architecture $abi'),
  };
  final redist = await selectedVisualStudioRedist();
  final platformRedist = Directory('${redist.path}/$architecture');
  if (!await platformRedist.exists()) {
    throw StateError(
      'Visual Studio $architecture redist is missing: ${platformRedist.path}',
    );
  }
  final crtDirectories = await platformRedist
      .list(followLinks: false)
      .where(
        (entry) =>
            entry is Directory &&
            RegExp(r'^Microsoft\.VC\d+\.CRT$', caseSensitive: false).hasMatch(
              entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
            ),
      )
      .cast<Directory>()
      .toList();
  if (crtDirectories.length != 1) {
    throw StateError(
      'Expected one release CRT in ${platformRedist.path}; '
      'found ${crtDirectories.length}',
    );
  }
  final crt = crtDirectories.single;
  final libraries = await crt
      .list(followLinks: false)
      .where(
        (entry) => entry is File && entry.path.toLowerCase().endsWith('.dll'),
      )
      .cast<File>()
      .toList();
  if (!libraries.any(
    (file) => file.uri.pathSegments.last.toLowerCase() == 'vcruntime140.dll',
  )) {
    throw StateError(
      'Visual Studio release CRT lacks VCRUNTIME140.dll: ${crt.path}',
    );
  }
  for (final destination in destinations) {
    if (!await destination.exists()) {
      throw StateError(
        'Windows bundle directory is missing: ${destination.path}',
      );
    }
    for (final library in libraries) {
      final name = library.uri.pathSegments.last;
      final bundled = File('${destination.path}/$name');
      if (await bundled.exists()) {
        final sourceBytes = await library.readAsBytes();
        final bundledBytes = await bundled.readAsBytes();
        if (sourceBytes.length != bundledBytes.length ||
            !identicalBytes(sourceBytes, bundledBytes)) {
          throw StateError(
            'Windows bundle contains a conflicting Visual C++ runtime: '
            '${bundled.path}',
          );
        }
      } else {
        await library.copy(bundled.path);
      }
    }
  }
}

Future<Directory> selectedVisualStudioRedist() async {
  final selectedRedist = environmentValue('VCToolsRedistDir');
  if (selectedRedist != null) return Directory(selectedRedist);

  var installation = environmentValue('VSINSTALLDIR');
  if (installation == null) {
    final programFiles = environmentValue('ProgramFiles(x86)');
    if (programFiles == null) {
      throw StateError(
        'ProgramFiles(x86) is unavailable; cannot locate Visual Studio',
      );
    }
    final vswhere = File(
      '$programFiles/Microsoft Visual Studio/Installer/vswhere.exe',
    );
    if (!await vswhere.exists()) {
      throw StateError('Visual Studio locator is missing: ${vswhere.path}');
    }
    final component = switch (Abi.current()) {
      Abi.windowsX64 => 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      Abi.windowsArm64 => 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
      final abi => throw UnsupportedError(
        'Windows toolchain architecture $abi',
      ),
    };
    final result = await Process.run(
      vswhere.path,
      [
        '-latest',
        '-products',
        '*',
        '-requires',
        component,
        '-property',
        'installationPath',
        '-utf8',
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    installation = (result.stdout as String).trim();
    if (result.exitCode != 0 || installation.isEmpty) {
      throw StateError(
        'Could not find a Visual Studio installation with $component: '
        '${result.stderr}',
      );
    }
  }
  final versionFile = File(
    '$installation/VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt',
  );
  if (!await versionFile.exists()) {
    throw StateError(
      'Visual Studio redist version is missing: ${versionFile.path}',
    );
  }
  final version = (await versionFile.readAsString()).trim();
  if (!RegExp(r'^\d+(?:\.\d+)+$').hasMatch(version)) {
    throw StateError('Invalid Visual Studio redist version: $version');
  }
  return Directory('$installation/VC/Redist/MSVC/$version');
}

String? environmentValue(String name) {
  for (final entry in Platform.environment.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase() &&
        entry.value.trim().isNotEmpty) {
      return entry.value.trim();
    }
  }
  return null;
}

bool identicalBytes(List<int> left, List<int> right) {
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Future<void> run(
  String executable,
  List<String> arguments,
  Directory directory,
) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: directory.path,
    runInShell: Platform.isWindows && executable.endsWith('.bat'),
    mode: ProcessStartMode.inheritStdio,
  );
  final result = await process.exitCode;
  if (result != 0) exit(result);
}

Future<void> copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entry in source.list(followLinks: false)) {
    final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final target = '${destination.path}/$name';
    if (entry is Link) {
      await Link(target).create(await entry.target());
    } else if (entry is Directory) {
      await copyDirectory(entry, Directory(target));
    } else if (entry is File) {
      await entry.copy(target);
    }
  }
}

Future<void> notices(Directory bundle) async {
  await File('${root.path}/LICENSE').copy('${bundle.path}/LICENSE');
  final notices = Directory('${bundle.path}/notices');
  await notices.create(recursive: true);
  for (final (path, name) in [
    ('packages/youtubei/NOTICE.md', 'YouTube-NOTICE.md'),
    ('packages/youtubei/FJS-LICENSE.txt', 'FJS-LICENSE.txt'),
    ('packages/sync-engine/lib/src/native_media/NOTICE.md', 'FFmpeg-NOTICE.md'),
    (
      'packages/sync-engine/lib/src/native_media/FFmpeg-LICENSE.txt',
      'FFmpeg-LICENSE.txt',
    ),
  ]) {
    final file = File('${root.path}/$path');
    if (await file.exists()) await file.copy('${notices.path}/$name');
  }
}
