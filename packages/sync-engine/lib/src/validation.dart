String nonblank(String value) {
  final result = value.trim();
  if (result.isEmpty) throw const FormatException('must not be blank');
  return result;
}

String slug(String value) {
  final result = nonblank(value);
  if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(result)) {
    throw const FormatException(
      'must use lowercase letters, numbers, and single hyphens',
    );
  }
  return result;
}

String language(String value) {
  final result = nonblank(value);
  if (!RegExp(r'^[a-z]{2}(?:-[A-Z]{2})?$').hasMatch(result)) {
    throw const FormatException('must use a language code such as en or en-US');
  }
  return result;
}

bool validId(String value, String prefix) =>
    value.startsWith(prefix) &&
    RegExp(r'^[0-9a-f]{16}$').hasMatch(value.substring(prefix.length));

String episodeId(String value) {
  if (!validId(value, 'ep_'))
    throw FormatException('invalid episode ID "$value"');
  return value;
}

bool credentialValid(String value) =>
    value.isNotEmpty && value.codeUnits.every((c) => c >= 0x21 && c <= 0x7e);

bool validTraceId(String value) =>
    RegExp(r'^[0-9a-f]{32}$').hasMatch(value) &&
    value != '00000000000000000000000000000000';

String redact(String message) => message
    .split(RegExp(r'\s+'))
    .map(
      (part) =>
          part.startsWith('https://') && part.contains('?') ? '[URL]' : part,
    )
    .join(' ');

Map<String, dynamic> jsonObject(Object? value, [String context = 'response']) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$context must be an object');
  }
  return value;
}

String jsonString(Map<String, dynamic> object, String key) {
  final value = object[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('response missing $key');
  }
  return value;
}

int jsonInt(Map<String, dynamic> object, String key) {
  final value = object[key];
  if (value is! int) throw FormatException('response missing numeric $key');
  return value;
}
