import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'validation.dart';

/// The whole client profile is shared by CLI and desktop.
class Config {
  const Config._({
    required this.directory,
    required this.apiOrigin,
    required this.dashboardOrigin,
  });

  final String directory;
  final String apiOrigin;
  final String dashboardOrigin;

  String get configPath => p.join(directory, 'config.yaml');
  String get authPath => p.join(directory, 'auth.json');
  String get sqlitePath => p.join(directory, 'sync.sqlite');
  String get downloadDirectory => p.join(directory, 'downloads');

  static Config load({
    String? explicitPath,
    String? profileDirectory,
    bool? debugProfile,
  }) {
    final directory = _profileDirectory(profileDirectory, debugProfile);
    return _loadIn(directory, explicitPath: explicitPath);
  }

  static Config _loadIn(String directory, {String? explicitPath}) {
    final path = explicitPath ?? p.join(directory, 'config.yaml');
    if (path.isEmpty)
      throw const FormatException('explicit config path is empty');
    Map<String, dynamic> values;
    final file = File(path);
    if (!file.existsSync() && explicitPath == null) {
      values = {
        'api_origin': 'https://v1.listenbox.app',
        'dashboard_origin': 'https://web.listenbox.app',
      };
    } else {
      String contents;
      try {
        contents = file.readAsStringSync();
      } on FileSystemException catch (error) {
        throw FormatException('load client config $path: ${error.message}');
      }
      try {
        final parsed = loadYaml(contents);
        if (parsed is! YamlMap)
          throw const FormatException('config must be a map');
        values = {};
        for (final key in parsed.keys) {
          if (key is! String ||
              !{'api_origin', 'dashboard_origin'}.contains(key)) {
            throw FormatException('unknown field $key');
          }
          final value = parsed[key];
          if (value is! String) throw FormatException('$key must be a string');
          values[key] = value;
        }
        if (values.length != 2) {
          throw const FormatException(
            'api_origin and dashboard_origin are required',
          );
        }
      } on YamlException catch (error) {
        throw FormatException('decode client config $path: $error');
      } on FormatException catch (error) {
        if (error.message.startsWith('unknown field')) rethrow;
        throw FormatException('decode client config $path: ${error.message}');
      }
    }
    return Config._(
      directory: directory,
      apiOrigin: _origin(values['api_origin'] as String, 'api_origin'),
      dashboardOrigin: _origin(
        values['dashboard_origin'] as String,
        'dashboard_origin',
      ),
    );
  }

  static Config loadIn(String directory, {String? explicitPath}) =>
      _loadIn(directory, explicitPath: explicitPath);

  String upgradeUrl(String team) {
    if (!validId(team, 'team_')) {
      throw const FormatException('invalid upgrade team identifier');
    }
    return '$dashboardOrigin/$team/upgrade';
  }

  String showUrl(String team, String show) {
    if (!validId(team, 'team_') || !validId(show, 'shw_')) {
      throw const FormatException('invalid show management identifiers');
    }
    return '$dashboardOrigin/$team/shows/$show';
  }
}

String _profileDirectory(String? explicit, bool? debugProfile) {
  final override = Platform.environment['LISTENBOX_PROFILE_DIR'];
  if (override != null) {
    if (override.isEmpty) {
      throw const FormatException('LISTENBOX_PROFILE_DIR is empty');
    }
    return override;
  }
  if (explicit != null) {
    if (explicit.isEmpty)
      throw const FormatException('profile directory is empty');
    return explicit;
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw const FormatException('resolve user home directory');
  }
  final debug = debugProfile ?? !const bool.fromEnvironment('dart.vm.product');
  if (debug) return p.join(home, '.cache', 'listenbox', 'dev');
  if (Platform.isMacOS) {
    return p.join(home, 'Library', 'Application Support', 'Listenbox');
  }
  if (Platform.isWindows) {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) {
      throw const FormatException('resolve user application data directory');
    }
    return p.join(local, 'Listenbox');
  }
  final xdg = Platform.environment['XDG_DATA_HOME'];
  return p.join(
    xdg == null || xdg.isEmpty ? p.join(home, '.local', 'share') : xdg,
    'listenbox',
  );
}

String _origin(String raw, String field) {
  try {
    final value = raw.trim();
    final separator = value.indexOf('://');
    if (separator < 0) throw const FormatException('missing HTTP(S) authority');
    final authorityAndPath = value.substring(separator + 3);
    if (authorityAndPath.isEmpty ||
        authorityAndPath.startsWith('/') ||
        authorityAndPath.contains(RegExp(r'[@\\?#]'))) {
      throw const FormatException(
        'origin must contain only a host and optional port',
      );
    }
    final slash = authorityAndPath.indexOf('/');
    if (slash >= 0 && slash != authorityAndPath.length - 1) {
      throw const FormatException('origin must not include a path');
    }
    final authority = slash < 0
        ? authorityAndPath
        : authorityAndPath.substring(0, slash);
    // Uri.parse percent-encodes spaces in an authority, so inspect the raw
    // authority before parsing rather than accepting a normalized host.
    if (authority.contains('%') ||
        authority.codeUnits.any((code) => code <= 0x20 || code == 0x7f) ||
        RegExp(r'\s').hasMatch(authority)) {
      throw const FormatException('invalid origin authority');
    }
    final uri = Uri.parse(value);
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.pathSegments.where((s) => s.isNotEmpty).isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port < 0 ||
        uri.port > 65535) {
      throw const FormatException('invalid origin URL');
    }
    return uri.origin;
  } on FormatException catch (error) {
    throw FormatException('validate $field: ${error.message}');
  }
}

/// Atomically replaces a private profile file after flushing its contents.
void writePrivateJson(String path, Object value) {
  final directory = p.dirname(path);
  ensurePrivateDirectory(directory);
  final random = Random.secure();
  final suffix = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final temporary = '$path.$suffix.tmp';
  final file = File(temporary);
  try {
    file.createSync(exclusive: true);
    _setMode(temporary, 0x180); // 0600
    final writer = file.openSync(mode: FileMode.writeOnly);
    try {
      writer.writeStringSync(
        '${const JsonEncoder.withIndent('  ').convert(value)}\n',
      );
      writer.flushSync();
    } finally {
      writer.closeSync();
    }
    file.renameSync(path);
    _syncDirectory(directory);
  } finally {
    if (file.existsSync()) file.deleteSync();
  }
}

void ensurePrivateDirectory(String path) {
  Directory(path).createSync(recursive: true);
  _setMode(path, 0x1c0); // 0700
}

void setPrivateFileMode(String path) => _setMode(path, 0x180); // 0600

typedef _ChmodNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _ChmodDart = int Function(Pointer<Utf8>, int);
typedef _OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDart = int Function(Pointer<Utf8>, int);
typedef _FdNative = Int32 Function(Int32);
typedef _FdDart = int Function(int);

final DynamicLibrary _process = DynamicLibrary.process();
final _ChmodDart _chmod = _process.lookupFunction<_ChmodNative, _ChmodDart>(
  'chmod',
);
final _OpenDart _open = _process.lookupFunction<_OpenNative, _OpenDart>('open');
final _FdDart _fsync = _process.lookupFunction<_FdNative, _FdDart>('fsync');
final _FdDart _close = _process.lookupFunction<_FdNative, _FdDart>('close');

void _setMode(String path, int mode) {
  if (Platform.isWindows) return;
  final native = path.toNativeUtf8();
  try {
    if (_chmod(native, mode) != 0) {
      throw FileSystemException('set private file permissions', path);
    }
  } finally {
    calloc.free(native);
  }
}

void _syncDirectory(String path) {
  if (Platform.isWindows) return;
  final native = path.toNativeUtf8();
  try {
    final fd = _open(native, 0);
    if (fd < 0) throw FileSystemException('open private directory', path);
    try {
      if (_fsync(fd) != 0)
        throw FileSystemException('flush private directory', path);
    } finally {
      _close(fd);
    }
  } finally {
    calloc.free(native);
  }
}

void removePrivateFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return;
  file.deleteSync();
  _syncDirectory(p.dirname(path));
}
