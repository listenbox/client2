import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenbox_desktop/desktop_host.dart';
import 'package:listenbox_desktop/main.dart';
import 'package:listenbox_sync_engine/sync_engine.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = _LoopbackTestBinding();
  setUpAll(() async {
    if (Platform.environment['LISTENBOX_DESIGN_CAPTURE'] == null) return;
    final family = Platform.isMacOS
        ? '.SF NS Text'
        : Platform.isWindows
        ? 'Segoe UI'
        : 'sans-serif';
    final file = Platform.isMacOS
        ? '/System/Library/Fonts/SFNS.ttf'
        : Platform.isWindows
        ? '${Platform.environment['WINDIR']}/Fonts/segoeui.ttf'
        : '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';
    await (FontLoader(
      family,
    )..addFont(File(file).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('workspace uses its real client and isolated profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 900);
    tester.view.devicePixelRatio = 1;
    await binding.setSurfaceSize(const Size(1080, 900));
    addTearDown(() => binding.setSurfaceSize(null));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = (await tester.runAsync(_DesktopFixture.start))!;
    final host = _HeadlessDesktopHost();
    final key = GlobalKey<DesktopWorkspaceState>();
    try {
      await tester.pumpWidget(
        ListenboxDesktop(key: key, client: service.client, host: host),
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

      expect(host.menu?.items?.map((item) => item.label), [
        'Open Listenbox',
        'Quit Listenbox',
      ]);
      state.onWindowClose();
      expect(state.windowHiddenSettled, isNotNull);
      await state.windowHiddenSettled!;
      expect(host.hidden, isTrue);
      expect(state.mounted, isTrue);
      expect(identical(state.client, service.client), isTrue);
      final catalogRequestsBefore = service.requests
          .where((request) => request == 'GET /s/shows')
          .length;
      await tester.runAsync(state.reload);
      expect(
        service.requests.where((request) => request == 'GET /s/shows').length,
        greaterThan(catalogRequestsBefore),
      );
      state.onTrayIconMouseDown();
      expect(host.popups, 1);
      state.onTrayIconRightMouseDown();
      expect(host.popups, 2);
      state.onTrayMenuItemClick(host.menu!.getMenuItem('show')!);
      expect(state.windowOpenSettled, isNotNull);
      await state.windowOpenSettled!;
      expect(host.hidden, isFalse);
      expect(host.opens, 1);

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

  testWidgets('Windows tray routes clicks and Quit closes the client', (
    tester,
  ) async {
    final service = (await tester.runAsync(_DesktopFixture.start))!;
    final host = _HeadlessDesktopHost(DesktopPlatform.windows);
    final key = GlobalKey<DesktopWorkspaceState>();
    try {
      await tester.pumpWidget(
        ListenboxDesktop(key: key, client: service.client, host: host),
      );
      final state = key.currentState!;
      expect(state.initialLoad, isNotNull);
      await tester.runAsync(() => state.initialLoad!);
      state.onTrayIconMouseDown();
      expect(state.windowOpenSettled, isNotNull);
      await state.windowOpenSettled!;
      expect(host.opens, 1);
      state.onTrayIconRightMouseDown();
      expect(host.popups, 1);
      expect(host.menu?.getMenuItem('quit'), isNotNull);
      state.onTrayMenuItemClick(host.menu!.getMenuItem('quit')!);
      await tester.runAsync(() => host.exited.future);
      expect(host.trayDestroyed, isTrue);
      expect(host.exitCode, 0);
      expect(state.stopping, isTrue);
      final requestsBefore = service.requests.length;
      await expectLater(service.client.catalog(), throwsA(isA<StateError>()));
      expect(service.requests.length, requestsBefore);
      expect(service.unexpected, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(service.close);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final dark in [false, true]) {
    testWidgets(
      'episode rows and durable issues in ${dark ? 'dark' : 'light'} appearance',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 1040);
        tester.view.devicePixelRatio = 1;
        await binding.setSurfaceSize(const Size(1080, 1040));
        addTearDown(() => binding.setSurfaceSize(null));
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final service = (await tester.runAsync(_DesktopFixture.start))!;
        const publishedVideo = 'abcdefghij1',
            pendingVideo = 'abcdefghij2',
            unavailableVideo = 'abcdefghij3';
        const publishedSource =
            'https://www.youtube.com/watch?v=$publishedVideo';
        const unavailableSource =
            'https://www.youtube.com/watch?v=$unavailableVideo';
        const publishedTitle = 'Pendulum - Blood Sugar (Guitar Cover)';
        const pendingTitle =
            'Nine Inch Nails - The Hand That Feeds (Guitar Cover)';
        const unavailableTitle = 'Pendulum - Self vs Self (Guitar Cover)';
        service.episodeRows[service.firstSlug] = [
          {
            'id': 'ep_${service.firstTeam.substring(5)}',
            'show_id': 'shw_${service.firstTeam.substring(5)}',
            'title': publishedTitle,
            'status': 'published',
            'duration_seconds': 318,
            'source_url': publishedSource,
            'source_position': 0,
          },
        ];
        await tester.runAsync(() async {
          final journal = await Database.open(service.profile);
          try {
            await journal.snapshot(
              service.client.config.apiOrigin,
              service.firstSlug,
              service.sourceUrl,
              [
                (url: publishedSource, title: publishedTitle, duration: 318),
                (
                  url: 'https://www.youtube.com/watch?v=$pendingVideo',
                  title: pendingTitle,
                  duration: 218,
                ),
                (
                  url: unavailableSource,
                  title: unavailableTitle,
                  duration: 286,
                ),
              ],
              canRemove: true,
            );
            await journal.published(
              service.client.config.apiOrigin,
              service.firstSlug,
              publishedSource,
            );
            final unavailable =
                Download(
                    id: '${service.firstSlug}/$unavailableVideo',
                    sourceId: service.firstSlug,
                    sourceTitle: 'First playlist',
                    title: unavailableTitle,
                    sourceUrl: unavailableSource,
                    position: 2,
                  )
                  ..phase = Phase.skipped
                  ..reason = 'Video unavailable'
                  ..durationSeconds = 286;
            await journal.outcome(
              service.client.config.apiOrigin,
              service.firstSlug,
              unavailable,
            );
          } finally {
            await journal.close();
          }
        });
        // The HTTP publication and production transfer projection intentionally
        // overlap while the app refreshes: they must render as one identity.
        final transfers = service.client.downloads.enqueue(
          service.firstSlug,
          'First playlist',
          [
            (id: publishedVideo, title: publishedTitle, position: 0),
            (id: pendingVideo, title: pendingTitle, position: 1),
          ],
        );
        transfers.first.phase(Phase.complete);
        transfers.last.startDownload(3000000);
        service.client.downloads
            .enqueue(service.secondSlug, 'Second playlist', [
              (id: 'abcdefghij4', title: 'Other podcast failure', position: 0),
            ])
            .single
            .error(StateError('Other podcast failure'));
        final boundary = GlobalKey();
        var key = GlobalKey<DesktopWorkspaceState>();
        final host = _HeadlessDesktopHost();
        try {
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: ListenboxDesktop(
                key: key,
                client: service.client,
                host: host,
              ),
            ),
          );
          await tester.runAsync(() => key.currentState!.initialLoad!);
          await tester.runAsync(
            () => key.currentState!.episodesSettled!.future,
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byKey(const Key('filter-episodes')));
          await tester.pump();
          expect(find.text(publishedTitle), findsOneWidget);
          expect(find.text(pendingTitle), findsOneWidget);
          expect(find.text('Published'), findsOneWidget);
          expect(find.text('Downloading'), findsOneWidget);
          expect(find.text(unavailableTitle), findsNothing);
          expect(find.text('Other podcast failure'), findsNothing);
          expect(find.text('Transfers'), findsNothing);
          expect(
            tester.getTopLeft(find.text(publishedTitle)).dy,
            lessThan(tester.getTopLeft(find.text(pendingTitle)).dy),
          );
          await _capture(
            tester,
            boundary,
            'episodes-${dark ? 'dark' : 'light'}',
          );
          await tester.tap(find.byKey(const Key('filter-not-imported')));
          await tester.pumpAndSettle();
          expect(find.text(unavailableTitle), findsOneWidget);
          expect(find.text('Video unavailable'), findsOneWidget);
          expect(find.text(publishedTitle), findsNothing);
          String? opened;
          key.currentState!.browserOpener = (url) async {
            opened = url;
          };
          await tester.tap(find.text('Open on YouTube'));
          expect(opened, unavailableSource);
          await _capture(
            tester,
            boundary,
            'not-imported-${dark ? 'dark' : 'light'}',
          );
          expect(tester.takeException(), isNull);

          await binding.setSurfaceSize(const Size(840, 600));
          tester.platformDispatcher.textScaleFactorTestValue = 1.25;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Open on YouTube'),
            220,
            scrollable: find.descendant(
              of: find.byKey(const Key('workspace-content')),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          await _capture(
            tester,
            boundary,
            'compact-not-imported-${dark ? 'dark' : 'light'}',
          );
          await tester.ensureVisible(find.byKey(const Key('filter-episodes')));
          await tester.tap(find.byKey(const Key('filter-episodes')));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(pendingTitle),
            220,
            scrollable: find.descendant(
              of: find.byKey(const Key('workspace-content')),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          await _capture(
            tester,
            boundary,
            'compact-episodes-${dark ? 'dark' : 'light'}',
          );

          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await binding.setSurfaceSize(const Size(1080, 1040));

          await tester.pumpWidget(const SizedBox.shrink());
          final config = service.client.config;
          await tester.runAsync(service.client.close);
          service.client = Client(config);
          key = GlobalKey<DesktopWorkspaceState>();
          await tester.pumpWidget(
            ListenboxDesktop(key: key, client: service.client, host: host),
          );
          await tester.runAsync(() => key.currentState!.initialLoad!);
          await tester.runAsync(
            () => key.currentState!.episodesSettled!.future,
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('filter-not-imported')),
          );
          await tester.tap(find.byKey(const Key('filter-not-imported')));
          await tester.pumpAndSettle();
          expect(find.text(unavailableTitle), findsOneWidget);
          expect(find.text('Video unavailable'), findsOneWidget);
          expect(service.unexpected, isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(service.close);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['LISTENBOX_DESIGN_CAPTURE'];
  if (directory == null) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await tester.runAsync(() async {
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
  } finally {
    image.dispose();
  }
}

class _LoopbackTestBinding extends LiveTestWidgetsFlutterBinding {
  // The fixture owns every URL used by this scenario, including artwork.
  @override
  bool get overrideHttpClient => false;
}

class _HeadlessDesktopHost implements DesktopHost {
  _HeadlessDesktopHost([this.platform = DesktopPlatform.macOS]);

  @override
  final DesktopPlatform platform;

  Menu? menu;
  bool hidden = false;
  bool trayDestroyed = false;
  int popups = 0;
  int opens = 0;
  int? exitCode;
  final exited = Completer<void>();

  @override
  void attach(
    WindowListener windowListener,
    TrayListener trayListener,
    Future<void> Function() requestQuit,
  ) {}

  @override
  void detach(WindowListener windowListener, TrayListener trayListener) {}

  @override
  Future<void> installTray(Menu menu) async {
    this.menu = menu;
  }

  @override
  Future<void> hideWindow() async {
    hidden = true;
  }

  @override
  Future<void> openWindow() async {
    opens++;
    hidden = false;
  }

  @override
  Future<void> popUpTrayMenu() async {
    popups++;
  }

  @override
  Future<void> destroyTray() async {
    trayDestroyed = true;
  }

  @override
  void exitProcess(int code) {
    exitCode = code;
    exited.complete();
  }
}

/// HTTP and OS window/tray calls are substituted: widgets use the production
/// Client, generated API, profile files, and cancellation/shutdown paths.
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
  late Client client;
  final episodeRows = <String, List<Map<String, Object>>>{};
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
      final slug = request.uri.path.split('/')[3];
      response = {'episodes': episodeRows[slug] ?? <Object>[]};
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
