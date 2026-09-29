import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:listenbox_desktop/main.dart';
import 'package:listenbox_sync_engine/sync_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native workspace uses its real client and isolated profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = (await tester.runAsync(_DesktopFixture.start))!;
    final key = GlobalKey<DesktopWorkspaceState>();
    try {
      await tester.pumpWidget(
        ListenboxDesktop(key: key, client: service.client),
      );
      final state = key.currentState!;
      expect(state.initialLoad, isNotNull);
      await tester.runAsync(() => state.initialLoad!);
      expect(state.episodesSettled, isNotNull);
      await tester.runAsync(() => state.episodesSettled!.future);
      await tester.pump();
      await tester.runAsync(() => service.artworkServed.future);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('show-${service.firstSlug}')), findsOneWidget);
      expect(find.byKey(Key('show-${service.secondSlug}')), findsOneWidget);
      expect(find.text('Ordinary podcast'), findsNothing);
      expect(find.text('No episodes synced yet.'), findsOneWidget);
      expect(service.requests, contains('GET /artwork.png'));
      expect(
        find.descendant(
          of: find.byKey(Key('show-${service.firstSlug}')),
          matching: find.byIcon(Icons.headphones),
        ),
        findsNothing,
      );
      expect(
        service.requests,
        containsAll([
          'GET /s/teams',
          'GET /s/shows',
          'GET /s/whoami',
          'GET /s/shows/${service.firstSlug}/episodes',
        ]),
      );

      await tester.tap(find.byKey(const Key('team-picker')));
      await tester.pump();
      await tester.tap(find.byKey(Key('team-${service.secondTeam}')));
      await tester.runAsync(() => state.episodesSettled!.future);
      await tester.pump();
      expect(find.byKey(Key('show-${service.firstSlug}')), findsNothing);
      expect(find.byKey(Key('show-${service.secondSlug}')), findsOneWidget);
      expect(state.selectedShow?['slug'], service.secondSlug);
      expect(
        service.requests,
        contains('GET /s/shows/${service.secondSlug}/episodes'),
      );

      String? opened;
      state.browserOpener = (url) async {
        opened = url;
      };
      await tester.tap(find.byKey(const Key('open-playlist')));
      await tester.pump();
      expect(opened, service.sourceUrl);

      await tester.tap(find.byKey(const Key('new-import')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('playlist-url')),
        'not a playlist',
      );
      await tester.ensureVisible(find.byKey(const Key('start-import')));
      await tester.tap(find.byKey(const Key('start-import')));
      expect(state.importSettled, isNotNull);
      await tester.runAsync(() => state.importSettled!.future);
      await tester.pump();
      expect(find.byKey(const Key('error-notice')), findsOneWidget);
      expect(
        service.requests.where((request) => request.startsWith('POST ')),
        isEmpty,
      );
      expect(state.selectedShow?['slug'], service.secondSlug);

      expect(File(service.client.config.authPath).existsSync(), isTrue);
      await tester.tap(find.byKey(const Key('account')));
      expect(state.logoutSettled, isNotNull);
      await tester.runAsync(() => state.logoutSettled!.future);
      await tester.pump();
      expect(service.client.hasCredentials, isFalse);
      expect(File(service.client.config.authPath).existsSync(), isFalse);
      expect(find.byKey(const Key('welcome-sign-in')), findsOneWidget);
      expect(service.unexpected, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(service.close);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

/// Only HTTP is a fixture: widgets use the production Client, generated API,
/// profile files, and cancellation/shutdown paths.
class _DesktopFixture {
  _DesktopFixture(
    this.profile,
    this.server,
    this.firstTeam,
    this.secondTeam,
    this.firstSlug,
    this.secondSlug,
    this.credential,
  );
  final Directory profile;
  final HttpServer server;
  final String firstTeam;
  final String secondTeam;
  final String firstSlug;
  final String secondSlug;
  final String credential;
  final requests = <String>[];
  final unexpected = <String>[];
  final artworkServed = Completer<void>();
  late final Client client;
  final sourceUrl = 'https://www.youtube.com/playlist?list=PLdesktopFixture';
  String get artworkUrl => 'http://localhost:${server.port}/artwork.png';

  static Future<_DesktopFixture> start() async {
    final random = Random.secure();
    String suffix() => List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final profile = await Directory.systemTemp.createTemp('listenbox-flutter-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _DesktopFixture(
      profile,
      server,
      'team_${suffix()}',
      'team_${suffix()}',
      'first-${suffix()}',
      'second-${suffix()}',
      'desktop-${suffix()}',
    );
    await File('${profile.path}/config.yaml').writeAsString(
      'api_origin: http://localhost:${server.port}\n'
      'dashboard_origin: http://localhost:${server.port}\n',
    );
    final config = Config.loadIn(profile.path);
    await File(config.authPath)
        .writeAsString(jsonEncode({'api_key': fixture.credential}));
    fixture.client = Client(config);
    server.listen(fixture.respond);
    return fixture;
  }

  Map<String, Object?> show(
    String slug,
    String team,
    String title, {
    bool imported = true,
  }) => {
    'has_active_subscription': false,
    'id': 'shw_${team.substring(5)}',
    'language': 'en',
    'slug': slug,
    'source_kind': 'audio',
    'team_id': team,
    'title': title,
    if (slug == firstSlug) 'image_url': artworkUrl,
    'youtube': imported
        ? {'kind': 'import', 'source_url': sourceUrl}
        : {'kind': 'none'},
  };

  Future<void> respond(HttpRequest request) async {
    final route = '${request.method} ${request.uri.path}';
    requests.add(route);
    await request.drain<void>();
    if (route == 'GET /artwork.png') {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNIaev/DwAFRAJ5mTYR+gAAAABJRU5ErkJggg==',
        ),
      );
      await request.response.close();
      if (!artworkServed.isCompleted) artworkServed.complete();
      return;
    }
    Object response;
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $credential') {
      unexpected.add('Missing profile authorization on $route');
      request.response.statusCode = HttpStatus.unauthorized;
      response = {'message': 'missing fixture authorization'};
    } else if (route == 'GET /s/teams') {
      response = [
        {'id': firstTeam, 'name': 'First team'},
        {'id': secondTeam, 'name': 'Second team'},
      ];
    } else if (route == 'GET /s/shows') {
      response = [
        show(firstSlug, firstTeam, 'First playlist'),
        show(secondSlug, secondTeam, 'Second playlist'),
        show('ordinary', firstTeam, 'Ordinary podcast', imported: false),
      ];
    } else if (route == 'GET /s/whoami') {
      response = {
        'id': 'apk_${firstTeam.substring(5)}',
        'email': 'desktop@example.test',
        'team_id': firstTeam,
        'scopes': ['team:read', 'show:read', 'show:create'],
      };
    } else if (route == 'GET /s/shows/$firstSlug/episodes' ||
        route == 'GET /s/shows/$secondSlug/episodes') {
      response = {'episodes': <Object>[]};
    } else {
      unexpected.add(route);
      request.response.statusCode = HttpStatus.notFound;
      response = {'message': 'unexpected fixture request'};
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
    await request.response.close();
  }

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
    await profile.delete(recursive: true);
  }
}
