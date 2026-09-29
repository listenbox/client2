import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'config.dart';

const youtubeCookieGuideUrl =
    'https://listenbox.app/guides/import-youtube-as-a-podcast/#when-youtube-asks-you-to-sign-in';
const _maxBytes = 1 << 20;
const _maxCookies = 1024;

class SignInRequired implements Exception {
  const SignInRequired([this.reason]);
  final String? reason;

  @override
  String toString() {
    final supplied = reason?.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    final detail = supplied == null || supplied.isEmpty
        ? 'YouTube needs a signed-in session.'
        : supplied.length > 256
        ? supplied.substring(0, 256)
        : supplied;
    final sentence = detail.endsWith('.') ? detail : '$detail.';
    return '$sentence Open Settings → YouTube to paste fresh cookies, or run listenbox youtube-cookies import <cookies.txt>, then sync again.';
  }
}

class _Cookie {
  _Cookie({
    required this.domain,
    required this.hostOnly,
    required this.path,
    required this.secure,
    required this.httpOnly,
    required this.expires,
    required this.name,
    required this.value,
    required this.revision,
  });

  final String domain;
  final bool hostOnly;
  final String path;
  final bool secure;
  final bool httpOnly;
  final int? expires;
  final String name;
  final String value;
  final String revision;

  String get key => '$domain\u0000$path\u0000$name';
  bool get expired =>
      expires != null &&
      expires! <= DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool matches(Uri url) {
    if (secure && url.scheme != 'https') return false;
    final host = url.host.toLowerCase();
    if (hostOnly
        ? host != domain
        : (host != domain && !host.endsWith('.$domain'))) {
      return false;
    }
    final targetPath = url.path.isEmpty ? '/' : url.path;
    return targetPath == path ||
        (targetPath.startsWith(path) &&
            (path.endsWith('/') ||
                (targetPath.length > path.length &&
                    targetPath[path.length] == '/')));
  }

  Map<String, Object?> toJson() => {
    'domain': domain,
    'host_only': hostOnly,
    'path': path,
    'secure': secure,
    'http_only': httpOnly,
    'expires': expires,
    'name': name,
    'value': value,
    'revision': revision,
  };

  factory _Cookie.fromJson(Object? value) {
    if (value is! Map<String, dynamic>)
      throw const FormatException('invalid cookie');
    final domain = value['domain'];
    final hostOnly = value['host_only'];
    final path = value['path'];
    final secure = value['secure'];
    final httpOnly = value['http_only'];
    final expires = value['expires'];
    final name = value['name'];
    final cookieValue = value['value'];
    final revision = value['revision'];
    if (domain is! String ||
        !_validDomain(domain) ||
        hostOnly is! bool ||
        path is! String ||
        !_validPath(path) ||
        secure is! bool ||
        httpOnly is! bool ||
        (expires != null && (expires is! int || expires < 0)) ||
        name is! String ||
        cookieValue is! String ||
        !_validPair(name, cookieValue) ||
        revision is! String ||
        revision.isEmpty ||
        !_validPrefixes(name, secure, hostOnly, path)) {
      throw const FormatException('invalid cookie');
    }
    return _Cookie(
      domain: domain,
      hostOnly: hostOnly,
      path: path,
      secure: secure,
      httpOnly: httpOnly,
      expires: expires as int?,
      name: name,
      value: cookieValue,
      revision: revision,
    );
  }
}

class CookieSnapshot {
  CookieSnapshot._(this.generation, this.enabled, this._entries);
  final String generation;
  final bool enabled;
  final List<_Cookie> _entries;

  String headerFor(Uri url) {
    if (!enabled ||
        url.scheme != 'https' ||
        !_youtubeDomain(url.host.toLowerCase())) {
      return '';
    }
    final matches = _entries
        .where((entry) => !entry.expired && entry.matches(url))
        .toList();
    matches.sort((a, b) {
      final pathOrder = b.path.length.compareTo(a.path.length);
      return pathOrder == 0 ? a.name.compareTo(b.name) : pathOrder;
    });
    return matches.map((entry) => '${entry.name}=${entry.value}').join('; ');
  }

  String? _revision(String key) {
    for (final entry in _entries) {
      if (entry.key == key) return entry.revision;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'generation': generation,
    'enabled': enabled,
    'entries': _entries.map((entry) => entry.toJson()).toList(),
  };

  factory CookieSnapshot.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['generation'] is! String ||
        value['enabled'] is! bool ||
        value['entries'] is! List) {
      throw const FormatException('invalid cookie snapshot');
    }
    final raw = value['entries'] as List;
    if (raw.length > _maxCookies)
      throw const FormatException('too many cookies');
    final entries = raw.map(_Cookie.fromJson).toList();
    if (entries.map((entry) => entry.key).toSet().length != entries.length) {
      throw const FormatException('duplicate saved cookies');
    }
    return CookieSnapshot._(
      value['generation'] as String,
      value['enabled'] as bool,
      entries,
    );
  }
}

/// Shared cross-process cookie store. Readers observe an atomic snapshot;
/// writers compare revisions while holding an OS file lock.
class CookieJar {
  CookieJar(String profileDirectory)
    : directory = p.join(profileDirectory, 'youtube-cookies');

  final String directory;
  String get path => p.join(directory, 'jar.json');
  String get _lockPath => p.join(directory, 'write.lock');

  Future<CookieSnapshot> snapshot() async {
    final file = File(path);
    if (!await file.exists()) return CookieSnapshot._('', false, []);
    try {
      if (await file.length() > _maxBytes)
        throw const FormatException('oversized jar');
      return CookieSnapshot.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      throw const FormatException(
        'Saved YouTube cookies are invalid. Replace them in Settings or with youtube-cookies import.',
      );
    }
  }

  Future<bool> isEnabled() async => (await snapshot()).enabled;

  Future<void> importFile(String sourcePath) async {
    final file = File(sourcePath);
    if (await file.length() > _maxBytes) {
      throw const FormatException('Cookie file is too large (maximum 1 MiB)');
    }
    final bytes = await file.readAsBytes();
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('Cookie export must be UTF-8 text');
    }
    await importText(text);
  }

  Future<void> importText(String text) async {
    final entries = _parseNetscape(text);
    final saved = CookieSnapshot._(_revision(), true, entries);
    await _withLock(() async => _save(saved));
  }

  Future<void> remove() async {
    await _withLock(
      () async => _save(CookieSnapshot._(_revision(), false, [])),
    );
  }

  Future<void> update(
    CookieSnapshot base,
    Uri url,
    Iterable<String> setCookieHeaders,
  ) async {
    if (!base.enabled ||
        url.scheme != 'https' ||
        !_youtubeDomain(url.host.toLowerCase()))
      return;
    final updates = <String, _Cookie>{};
    var received = 0;
    for (final folded in setCookieHeaders) {
      // package:http folds repeated response headers with commas. A cookie
      // value cannot contain a comma; an Expires date can, but is not followed
      // by a cookie-name and equals sign.
      for (final header in folded.split(
        RegExp(r',\s*(?=[A-Za-z0-9!#\$%&\x27*+.^_`|~-]+=)'),
      )) {
        if (++received > _maxCookies) break;
        if (header.length > 16 << 10) continue;
        final cookie = _parseSetCookie(url, header);
        if (cookie != null) updates[cookie.key] = cookie;
      }
      if (received > _maxCookies) break;
    }
    if (updates.isEmpty) return;
    await _withLock(() async {
      final current = await snapshot();
      if (!current.enabled || current.generation != base.generation) return;
      final entries = current._entries.toList();
      var changed = false;
      for (final cookie in updates.values) {
        if (current._revision(cookie.key) != base._revision(cookie.key))
          continue;
        final index = entries.indexWhere((entry) => entry.key == cookie.key);
        if (index >= 0) {
          entries[index] = cookie;
        } else {
          if (entries.length >= _maxCookies) {
            throw const FormatException(
              'YouTube cookie jar is full; import a fresh export',
            );
          }
          entries.add(cookie);
        }
        changed = true;
      }
      if (changed)
        await _save(CookieSnapshot._(current.generation, true, entries));
    });
  }

  Future<void> _save(CookieSnapshot saved) async {
    final bytes = utf8.encode(jsonEncode(saved.toJson()));
    if (bytes.length >= _maxBytes) {
      throw const FormatException(
        'YouTube cookie jar is too large; export a smaller YouTube session',
      );
    }
    writePrivateJson(path, saved.toJson());
  }

  Future<T> _withLock<T>(Future<T> Function() operation) async {
    ensurePrivateDirectory(directory);
    final lock = File(_lockPath);
    if (!lock.existsSync()) {
      lock.createSync();
      setPrivateFileMode(_lockPath);
    }
    final handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return await operation();
    } finally {
      await handle.unlock();
      await handle.close();
    }
  }
}

List<_Cookie> _parseNetscape(String input) {
  if (utf8.encode(input).length > _maxBytes) {
    throw const FormatException('Cookie export is too large (maximum 1 MiB)');
  }
  final lines = input.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'));
  if (lines.isEmpty ||
      !{
        '# Netscape HTTP Cookie File',
        '# HTTP Cookie File',
      }.contains(lines.first.trim())) {
    throw const FormatException(
      'Paste the entire Netscape cookies.txt export, including its header. JSON is not supported.',
    );
  }
  final entries = <_Cookie>[];
  final keys = <String>{};
  for (var index = 1; index < lines.length; index++) {
    var line = lines[index];
    var httpOnly = false;
    if (line.startsWith('#HttpOnly_')) {
      line = line.substring('#HttpOnly_'.length);
      httpOnly = true;
    } else if (line.startsWith('#') || line.trim().isEmpty) {
      continue;
    }
    final fields = line.split('\t');
    FormatException invalid() => FormatException(
      'Invalid cookies.txt row ${index + 1}. Export cookies in Netscape format again.',
    );
    if (fields.length != 7) throw invalid();
    final host = fields[0].replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    if (!_youtubeDomain(host)) continue;
    final subdomains = fields[1];
    final cookiePath = fields[2];
    final secure = fields[3];
    final expires = int.tryParse(fields[4]);
    final name = fields[5];
    final value = fields[6];
    if (!{'TRUE', 'FALSE'}.contains(subdomains) ||
        !{'TRUE', 'FALSE'}.contains(secure) ||
        !_validPath(cookiePath) ||
        !_validPair(name, value) ||
        expires == null ||
        expires < 0 ||
        !_validDomain(host) ||
        !_validPrefixes(
          name,
          secure == 'TRUE',
          subdomains == 'FALSE',
          cookiePath,
        )) {
      throw invalid();
    }
    if (expires != 0 &&
        expires <= DateTime.now().millisecondsSinceEpoch ~/ 1000)
      continue;
    final cookie = _Cookie(
      domain: host,
      hostOnly: subdomains == 'FALSE',
      path: cookiePath,
      secure: secure == 'TRUE',
      httpOnly: httpOnly,
      expires: expires == 0 ? null : expires,
      name: name,
      value: value,
      revision: _revision(),
    );
    if (!keys.add(cookie.key)) {
      throw FormatException(
        'Duplicate cookie in row ${index + 1}; export cookies again',
      );
    }
    entries.add(cookie);
    if (entries.length > _maxCookies) {
      throw const FormatException('Too many YouTube cookies in this export');
    }
  }
  if (entries.isEmpty) {
    throw const FormatException(
      'No unexpired YouTube cookies found. Export a fresh YouTube session.',
    );
  }
  return entries;
}

_Cookie? _parseSetCookie(Uri url, String header) {
  final parts = header.split(';');
  final separator = parts.first.indexOf('=');
  if (separator < 1) return null;
  final name = parts.first.substring(0, separator).trim();
  final value = parts.first.substring(separator + 1).trim();
  if (!_validPair(name, value)) return null;
  var domain = url.host.toLowerCase();
  var hostOnly = true;
  var cookiePath = '/';
  var secure = false;
  var httpOnly = false;
  int? expires;
  for (final raw in parts.skip(1)) {
    final separator = raw.indexOf('=');
    final key = (separator < 0 ? raw : raw.substring(0, separator))
        .trim()
        .toLowerCase();
    final attribute = separator < 0 ? '' : raw.substring(separator + 1).trim();
    switch (key) {
      case 'domain':
        domain = attribute.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
        hostOnly = false;
      case 'path':
        cookiePath = attribute;
      case 'secure':
        secure = true;
      case 'httponly':
        httpOnly = true;
      case 'max-age':
        final age = int.tryParse(attribute);
        if (age == null) return null;
        expires = age <= 0
            ? 1
            : DateTime.now().millisecondsSinceEpoch ~/ 1000 + age;
      case 'expires':
        if (expires == null) {
          try {
            expires = HttpDate.parse(attribute).millisecondsSinceEpoch ~/ 1000;
          } on FormatException {
            return null;
          }
        }
    }
  }
  if (!_validDomain(domain) ||
      !(url.host.toLowerCase() == domain ||
          url.host.toLowerCase().endsWith('.$domain')) ||
      !_validPath(cookiePath) ||
      !_validPrefixes(name, secure, hostOnly, cookiePath))
    return null;
  return _Cookie(
    domain: domain,
    hostOnly: hostOnly,
    path: cookiePath,
    secure: secure,
    httpOnly: httpOnly,
    expires: expires,
    name: name,
    value: value,
    revision: _revision(),
  );
}

bool _youtubeDomain(String domain) =>
    domain == 'youtube.com' || domain.endsWith('.youtube.com');
bool _validDomain(String domain) =>
    RegExp(r'^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*youtube\.com$')
        .hasMatch(domain);
bool _validPath(String path) =>
    path.startsWith('/') &&
    path.codeUnits.every((c) => c > 0x20 && c < 0x7f && c != 0x3b);
bool _validPair(String name, String value) =>
    RegExp(r"^[A-Za-z0-9!#\$%&'*+.^_`|~-]+$").hasMatch(name) &&
    value.codeUnits.every(
      (c) =>
          c >= 0x21 &&
          c <= 0x7e &&
          c != 0x22 &&
          c != 0x3b &&
          c != 0x2c &&
          c != 0x5c,
    );
bool _validPrefixes(String name, bool secure, bool hostOnly, String path) =>
    (!name.startsWith('__Secure-') || secure) &&
    (!name.startsWith('__Host-') || (secure && hostOnly && path == '/'));

String _revision() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
