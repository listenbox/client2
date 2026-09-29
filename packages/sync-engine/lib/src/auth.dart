import 'dart:async';

import 'api.dart';
import 'config.dart';
import 'events.dart';
import 'publicapi/models.dart' as p;
import 'validation.dart';

class Auth {
  static const scopes = [
    p.ApiKeyScope.teamRead,
    p.ApiKeyScope.teamManage,
    p.ApiKeyScope.showRead,
    p.ApiKeyScope.showCreate,
    p.ApiKeyScope.showUpdate,
    p.ApiKeyScope.episodeCreate,
    p.ApiKeyScope.episodeDelete,
    p.ApiKeyScope.episodeUpdate,
    p.ApiKeyScope.episodePublish,
  ];

  static Future<void> login(
    Api api, {
    String client = 'cli',
    required FutureOr<void> Function(Uri url) openBrowser,
  }) async {
    if (client != 'cli' && client != 'desktop') {
      throw const FormatException('invalid authorization client');
    }
    final body = p.CreateCLIAuthorization(
      client: client == 'cli'
          ? p.AuthorizationClient.cli
          : p.AuthorizationClient.desktop,
      scopes: scopes,
    );
    p.CreatedCLIAuthorization pending;
    try {
      pending = await api.publicClient.createCLIAuthorization(body: body);
    } on AuthenticationRequired {
      if (!api.hasCredential) rethrow;
      api.setCredential(null);
      pending = await api.publicClient.createCLIAuthorization(body: body);
    }
    final version = api.credentialVersion;
    if (!credentialValid(pending.credential)) {
      throw const FormatException('invalid pending credential');
    }
    final verifiedUrl = Uri.parse(pending.verificationUrl);
    if ((verifiedUrl.scheme != 'http' && verifiedUrl.scheme != 'https') ||
        !verifiedUrl.hasAuthority ||
        verifiedUrl.host.isEmpty ||
        verifiedUrl.userInfo.isNotEmpty ||
        verifiedUrl.hasFragment) {
      throw const FormatException('invalid verification URL');
    }
    final dashboard = Uri.parse(api.config.dashboardOrigin);
    final verification = Uri(
      scheme: dashboard.scheme,
      host: dashboard.host,
      port: dashboard.hasPort ? dashboard.port : null,
      path: verifiedUrl.path,
      query: verifiedUrl.hasQuery ? verifiedUrl.query : null,
    );
    await openBrowser(verification);
    final stream = await EventStream.fromResponse(
      api,
      await api.publicClient.cliAuthorizationEvents(code: pending.code),
    );
    try {
      final event = await stream.next();
      switch (jsonString(event, 'type')) {
        case 'cli.authorization.approved':
          final approved = p.CLIAuthorizationApprovedEvent.fromJson(event);
          if (api.credentialVersion != version) {
            throw StateError('authorization changed while signing in');
          }
          api.setCredential(pending.credential);
          final pendingVersion = api.credentialVersion;
          try {
            final identity = await api.publicClient.whoami();
            if (api.credentialVersion != pendingVersion) {
              throw StateError('authorization changed while signing in');
            }
            if (identity.teamId != approved.teamId) {
              throw const FormatException(
                'approved credential team does not match approved team',
              );
            }
            for (final scope in scopes) {
              if (!identity.scopes.contains(scope)) {
                throw FormatException(
                  'approved credential missing scope $scope',
                );
              }
            }
            if (api.credentialVersion != pendingVersion) {
              throw StateError('authorization changed while signing in');
            }
            writePrivateJson(api.config.authPath, {
              'api_key': pending.credential,
            });
          } catch (_) {
            if (api.credentialVersion == pendingVersion)
              api.setCredential(null);
            rethrow;
          }
        case 'cli.authorization.denied':
          p.CLIAuthorizationDeniedEvent.fromJson(event);
          throw const FormatException('Authorization was denied');
        case 'cli.authorization.expired':
          p.CLIAuthorizationExpiredEvent.fromJson(event);
          throw const FormatException('Authorization expired');
        default:
          throw FormatException(
            'unexpected authorization event ${event['type']}',
          );
      }
    } finally {
      await stream.close();
    }
  }

  /// Call after stopping admission and awaiting all application-owned work.
  static Future<void> logout(Api api) async {
    api.setCredential(null);
    removePrivateFile(api.config.authPath);
  }

  static Future<String> status(Api api) async {
    final identity = await api.publicClient.whoami();
    final email = identity.email.trim();
    if (email.isEmpty) throw const FormatException('identity email is empty');
    final name = identity.name?.trim().split(RegExp(r'\s+')).join(' ') ?? '';
    return name.isEmpty ? 'Logged in as $email' : 'Logged in as $name <$email>';
  }
}
