import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:yaml/yaml.dart';

/// DESIGN.md owns the values; the committed snapshot makes standalone client
/// builds independent of the parent checkout. Both workspaces check the bridge.
Future<void> main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent;
  final snapshot = File('${root.path}/design/tokens.json');
  final generated = File(
    '${root.path}/packages/desktop/lib/design_tokens.dart',
  );
  final check = args.contains('--check');
  final sourceIndex = args.indexOf('--source');
  Map<String, dynamic> tokens;
  if (sourceIndex >= 0) {
    final source = File(args[sourceIndex + 1]).readAsStringSync();
    final frontmatter = source.split('---')[1];
    final document = jsonDecode(jsonEncode(loadYaml(frontmatter))) as Map;
    tokens = {
      for (final name in [
        'colors',
        'typography',
        'rounded',
        'spacing',
        'components',
      ])
        name: document[name],
    };
    await _write(
      snapshot,
      '${const JsonEncoder.withIndent('  ').convert(tokens)}\n',
      check,
    );
  } else {
    tokens = jsonDecode(snapshot.readAsStringSync()) as Map<String, dynamic>;
  }
  final code = StringBuffer(
    '''// Generated from DESIGN.md by tool/design.dart. Do not edit.
import 'package:flutter/material.dart';

abstract final class DesignTokens {
''',
  );
  final colors = tokens['colors'] as Map;
  for (final entry in colors.entries) {
    code.writeln(
      '  static const ${_name(entry.key as String)} = Color(0xff${_rgb(entry.value as String)});',
    );
  }
  for (final section in ['rounded', 'spacing']) {
    for (final entry in (tokens[section] as Map).entries) {
      final prefix = section == 'rounded' ? 'radius' : 'space';
      code.writeln(
        '  static const ${_name('$prefix-${entry.key}')} = ${_pixels(entry.value as String)};',
      );
    }
  }
  for (final name in [
    'page-title',
    'title',
    'body',
    'field',
    'label',
    'button',
    'support',
  ]) {
    final style = (tokens['typography'] as Map)[name] as Map;
    final size = _pixels(style['fontSize'] as String);
    final weight = ((style['fontWeight'] as int) / 100).round() * 100;
    final tracking =
        double.parse((style['letterSpacing'] as String).replaceAll('em', '')) *
        size;
    code.writeln('  static const ${_name('$name-type')} = TextStyle(');
    code.writeln('    fontSize: $size,');
    code.writeln('    fontWeight: FontWeight.w$weight,');
    code.writeln('    height: ${style['lineHeight']},');
    code.writeln('    letterSpacing: $tracking,');
    code.writeln('  );');
  }
  for (final entry in (tokens['components'] as Map).entries) {
    final component = entry.value as Map;
    final name = _name(entry.key as String);
    if (component['height'] case final String height) {
      code.writeln('  static const ${name}Height = ${_pixels(height)};');
    }
    if (component['padding'] case final String padding) {
      final values = padding.split(' ').map(_pixels).toList();
      final top = values[0], right = values.length == 1 ? top : values[1];
      final bottom = values.length < 3 ? top : values[2];
      final left = values.length < 4 ? right : values[3];
      code.writeln('  static const ${name}Padding = EdgeInsets.fromLTRB(');
      code.writeln('    $left, $top, $right, $bottom,');
      code.writeln('  );');
    }
  }
  code.writeln('}');
  final formatter = await Process.start(Platform.resolvedExecutable, [
    'format',
    '--output=show',
    '--summary=none',
  ]);
  formatter.stdin.write(code);
  await formatter.stdin.close();
  final output = formatter.stdout.transform(utf8.decoder).join();
  final errors = formatter.stderr.transform(utf8.decoder).join();
  final formatted = await output;
  if (await formatter.exitCode != 0) throw FormatException(await errors);
  await errors;
  await _write(generated, formatted, check);
}

Future<void> _write(File file, String expected, bool check) async {
  if (check) {
    if (!file.existsSync() || file.readAsStringSync() != expected) {
      stderr.writeln(
        'Design tokens drifted: ${file.path}. Regenerate with tool/design.dart.',
      );
      exitCode = 1;
    }
  } else {
    await file.parent.create(recursive: true);
    await file.writeAsString(expected);
  }
}

String _name(String value) {
  final parts = value.split('-');
  return '${parts.first}${parts.skip(1).map((part) => '${part[0].toUpperCase()}${part.substring(1)}').join()}';
}

double _pixels(String value) => value.endsWith('rem')
    ? double.parse(value.replaceAll('rem', '')) * 16
    : double.parse(value.replaceAll('px', ''));

String _rgb(String value) {
  if (value.startsWith('#')) return value.substring(1);
  final values = value
      .replaceAll('oklch(', '')
      .replaceAll(')', '')
      .split(' ')
      .map(double.parse)
      .toList();
  final l = values[0],
      a = values[1] * math.cos(values[2] * math.pi / 180),
      b = values[1] * math.sin(values[2] * math.pi / 180);
  final lm = math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3).toDouble();
  final mm = math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3).toDouble();
  final sm = math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3).toDouble();
  return [
    4.0767416621 * lm - 3.3077115913 * mm + 0.2309699292 * sm,
    -1.2684380046 * lm + 2.6097574011 * mm - 0.3413193965 * sm,
    -0.0041960863 * lm - 0.7034186147 * mm + 1.7076147010 * sm,
  ].map((linear) {
    final srgb = linear <= 0.0031308
        ? 12.92 * linear
        : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
    return (srgb.clamp(0, 1) * 255).round().toRadixString(16).padLeft(2, '0');
  }).join();
}
