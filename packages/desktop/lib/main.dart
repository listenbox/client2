import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:listenbox_sync_engine/sync_engine.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

/// The client belongs to the running app, so a Flutter hot reload rebuilds the
/// interface without reopening SQLite or cancelling admitted transfers.
Future<void> main(List<String> args) => launchDesktop(args);

Future<void> launchDesktop(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final nativeArgs = Platform.isMacOS
      ? (await const MethodChannel('listenbox/native')
                .invokeListMethod<String>('arguments')) ??
            args
      : args;
  final configArg = nativeArgs.indexOf('--config');
  if (configArg >= 0 && configArg + 1 >= nativeArgs.length) {
    throw const FormatException('--config requires a path');
  }
  String? configPath = configArg < 0 ? null : nativeArgs[configArg + 1];
  configPath ??= Platform.environment['LISTENBOX_CONFIG'];
  if (configPath == null && !const bool.fromEnvironment('dart.vm.product')) {
    final checkoutConfig = File('../../config/dev.yaml');
    if (!checkoutConfig.existsSync()) {
      throw const FormatException(
        'Development config not found. Set LISTENBOX_CONFIG to config/dev.yaml.',
      );
    }
    configPath = checkoutConfig.absolute.path;
  }
  final config = Config.load(explicitPath: configPath);
  if (!const bool.fromEnvironment('dart.vm.product')) {
    stderr.writeln('Listenbox desktop profile: ${config.directory}');
    stderr.writeln('Listenbox API: ${config.apiOrigin}');
  }
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.setMinimumSize(const Size(840, 600));
  unawaited(
    windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1080, 760),
        center: true,
        title: 'Listenbox',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    ),
  );
  runApp(ListenboxDesktop(client: Client(config)));
}

class ListenboxDesktop extends StatefulWidget {
  const ListenboxDesktop({super.key, required this.client});
  final Client client;
  @override
  State<ListenboxDesktop> createState() => DesktopWorkspaceState();
}

class _Palette {
  const _Palette(this.dark);
  final bool dark;
  Color get background =>
      dark ? const Color(0xff242424) : const Color(0xfffcfcfc);
  Color get rail => dark ? const Color(0xff292929) : const Color(0xfff1f1f1);
  Color get sheet => dark ? const Color(0xff2b2b2b) : Colors.white;
  Color get ink => dark ? const Color(0xfff8f8f8) : const Color(0xff303030);
  Color get muted => dark ? const Color(0xffcccccc) : const Color(0xff656565);
  Color get border => dark ? const Color(0xff777777) : const Color(0xff999999);
  Color get divider => dark ? const Color(0xff444444) : const Color(0xffe7e7e7);
  Color get selected =>
      dark ? const Color(0xff484848) : const Color(0xffe6e6e6);
  Color get action => dark ? const Color(0xff727272) : const Color(0xff303030);
  Color get danger => dark ? const Color(0xffef9a8d) : const Color(0xffb44d42);
}

class _Notice {
  const _Notice(this.message, {this.upgradeUrl, this.signIn = false});
  final String message;
  final String? upgradeUrl;
  final bool signIn;
}

class DesktopWorkspaceState extends State<ListenboxDesktop>
    with WindowListener, TrayListener {
  Catalog? catalog;
  String? teamId;
  String? selectedSlug;
  bool teamPicker = false;
  bool importing = false;
  bool importOpen = false;
  bool importVideo = false;
  bool loading = false;
  bool authenticating = false;
  bool settingsOpen = false;
  bool cookieBusy = false;
  bool cookieSaved = false;
  bool stopping = false;
  bool _autoSyncStarted = false;
  bool _episodeLoading = false;
  String? _episodeCursor;
  String? _episodeError;
  String? _cookieMessage;
  String? _cookieError;
  _Notice? notice;
  List<Map<String, dynamic>> episodes = [];
  final Map<String, CancellationToken> _jobs = {};
  final Map<String, String> _reports = {};
  final TextEditingController source = TextEditingController();
  final TextEditingController cookieText = TextEditingController();
  CancellationToken _life = CancellationToken();
  CancellationToken? _episodeCancel;
  CancellationToken? _importCancel;
  StreamSubscription<DownloadSnapshot>? _downloadSubscription;
  DownloadSnapshot? progress;
  int _episodeRequest = 0;
  bool _trayInstalled = false;
  bool _quitRequested = false;
  Future<void>? initialLoad;
  final Map<String, Completer<void>> syncSettled = {};
  Completer<void>? episodesSettled;
  Completer<void>? settingsSettled;
  Completer<void>? cookiesSettled;
  Completer<void>? importSettled;
  Completer<void>? logoutSettled;
  Future<void> Function(String)? browserOpener;

  Client get client => widget.client;
  bool get loaded => catalog != null;
  List<Map<String, dynamic>> get shows =>
      catalog?.shows.where(_isImport).toList() ?? const [];
  Map<String, dynamic>? get selectedShow {
    for (final show in shows) {
      if (show['slug'] == selectedSlug) return show;
    }
    return null;
  }

  static bool _isImport(Map<String, dynamic> show) {
    final youtube = show['youtube'];
    return youtube is Map && youtube['kind'] == 'import';
  }

  String _string(Map<String, dynamic> row, String key) =>
      row[key] is String ? row[key] as String : '';
  String _teamName(String? id) {
    for (final team in catalog?.teams ?? const <Map<String, dynamic>>[]) {
      if (team['id'] == id) return _string(team, 'name');
    }
    return 'your authorized team';
  }

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) {
      const MethodChannel('listenbox/native')
          .setMethodCallHandler((call) async {
            if (call.method == 'quitRequested') await quit();
          });
    }
    windowManager.addListener(this);
    trayManager.addListener(this);
    progress = client.downloads.snapshot();
    _downloadSubscription = client.downloads.changes.listen((value) {
      if (mounted) setState(() => progress = value);
    });
    unawaited(_installTray());
    if (client.hasCredentials) initialLoad = reload();
  }

  Future<void> _installTray() async {
    try {
      final asset = Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png';
      final bytes = await rootBundle.load(asset);
      final extension = Platform.isWindows ? 'ico' : 'png';
      final file = File(
        '${Directory.systemTemp.path}/listenbox-tray-$pid.$extension',
      );
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      await trayManager.setIcon(file.path, isTemplate: Platform.isMacOS);
      await trayManager.setToolTip('Listenbox — YouTube to podcast sync');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Open Listenbox'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit Listenbox'),
          ],
        ),
      );
      _trayInstalled = true;
    } catch (error) {
      // A missing status item must not prevent the workspace from opening.
      stderr.writeln('Listenbox status item unavailable: $error');
    }
  }

  @override
  void onWindowClose() {
    unawaited(windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(windowManager.show().then((_) => windowManager.focus()));
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'show') onTrayIconMouseDown();
    if (item.key == 'quit') unawaited(quit());
  }

  Future<void> quit() async {
    if (_quitRequested) return;
    _quitRequested = true;
    setState(() => stopping = true);
    _life.cancel();
    _episodeCancel?.cancel();
    _importCancel?.cancel();
    for (final token in _jobs.values) {
      token.cancel();
    }
    try {
      await client.close();
      if (_trayInstalled) await trayManager.destroy();
      exit(0);
    } catch (error) {
      stderr.writeln('Could not finish shutdown: $error');
      exitCode = 1;
    }
  }

  Future<void> logout() async {
    if (stopping) return;
    logoutSettled = Completer<void>();
    setState(() {
      stopping = true;
      notice = null;
    });
    _life.cancel();
    _episodeCancel?.cancel();
    _importCancel?.cancel();
    for (final token in _jobs.values) {
      token.cancel();
    }
    try {
      await client.logout();
      if (!mounted) return;
      _life = CancellationToken();
      setState(() {
        catalog = null;
        teamId = null;
        selectedSlug = null;
        teamPicker = false;
        importOpen = false;
        settingsOpen = false;
        importing = false;
        _autoSyncStarted = false;
        _jobs.clear();
        _reports.clear();
        episodes = [];
        progress = client.downloads.snapshot();
        stopping = false;
      });
    } catch (error) {
      if (mounted)
        setState(() {
          stopping = false;
          notice = _Notice('Could not sign out. $error');
        });
    } finally {
      logoutSettled?.complete();
    }
  }

  Future<void> login() async {
    if (authenticating || stopping) return;
    setState(() {
      authenticating = true;
      notice = null;
    });
    try {
      await client.login((url) => _open(url.toString()), cancel: _life);
      await reload();
    } catch (error) {
      if (mounted)
        setState(() => notice = _Notice('Sign-in did not finish. $error'));
    } finally {
      if (mounted) setState(() => authenticating = false);
    }
  }

  Future<void> reload({bool preserveNotice = false}) async {
    if (loading || stopping) return;
    setState(() {
      loading = true;
      if (!preserveNotice) notice = null;
    });
    try {
      final result = await client.catalog(cancel: _life);
      if (!mounted || stopping) return;
      final filtered = Catalog(
        teams: result.teams,
        importTeam: result.importTeam,
        shows: result.shows.where(_isImport).toList(),
      );
      setState(() {
        catalog = filtered;
        if (!shows.any((show) => show['slug'] == selectedSlug)) {
          selectedSlug =
              shows
                      .where(
                        (show) => teamId == null || show['team_id'] == teamId,
                      )
                      .firstOrNull?['slug']
                  as String?;
        }
      });
      if (selectedSlug != null) unawaited(loadEpisodes());
      _startAutoSync();
    } on AuthenticationRequired {
      if (mounted)
        setState(() {
          catalog = null;
          selectedSlug = null;
          episodes = [];
        });
    } catch (error) {
      if (mounted)
        setState(() => notice = _Notice('Could not load podcasts. $error'));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _startAutoSync() {
    if (_autoSyncStarted || !client.hasCredentials) return;
    _autoSyncStarted = true;
    syncAll(onlyNew: true);
    unawaited(() async {
      while (await client.nextScan(_life)) {
        if (!mounted || stopping) break;
        syncAll();
      }
    }());
  }

  void syncAll({bool onlyNew = false}) {
    for (final show in shows) {
      final slug = _string(show, 'slug');
      if (show['has_active_subscription'] == true &&
          (!onlyNew || !_reports.containsKey(slug))) {
        unawaited(syncShow(slug));
      }
    }
  }

  Future<void> syncShow(String slug) async {
    if (stopping || !loaded || _jobs.containsKey(slug)) return;
    final settled = Completer<void>();
    syncSettled[slug] = settled;
    final token = _life.child();
    setState(() {
      _jobs[slug] = token;
      _reports[slug] = 'Reading YouTube and Listenbox…';
    });
    try {
      await client.sync(
        slug,
        cancel: token,
        onReport: (report) {
          if (!mounted || stopping) return;
          setState(() => _reports[slug] = _reportText(report));
          if (selectedSlug == slug) unawaited(loadEpisodes());
        },
      );
    } on OperationCancelled {
      if (mounted && !stopping)
        setState(
          () =>
              _reports[slug] = 'Stopped. Progress is saved for the next sync.',
        );
    } on SignInRequired {
      if (mounted && !stopping)
        setState(() {
          notice = const _Notice(
            'YouTube is asking you to sign in. Add fresh cookies in Settings, then use Sync now to continue this podcast.',
            signIn: true,
          );
          _reports[slug] =
              'YouTube sign-in required. Open Settings to add fresh cookies.';
        });
    } catch (error) {
      if (mounted && !stopping)
        setState(() => _reports[slug] = 'Sync failed. $error');
    } finally {
      if (mounted) setState(() => _jobs.remove(slug));
      settled.complete();
    }
  }

  String _reportText(Report report) =>
      '${report.added} added · ${report.removed} removed · ${report.unchanged} unchanged · ${report.skipped} skipped${report.reordered ? ' · Order updated' : ''}';

  void selectShow(String? slug) {
    _episodeCancel?.cancel();
    setState(() {
      selectedSlug = slug;
      importOpen = false;
      settingsOpen = false;
      episodes = [];
      _episodeCursor = null;
      _episodeError = null;
    });
    if (slug != null) unawaited(loadEpisodes());
  }

  Future<void> loadEpisodes({bool append = false}) async {
    if (append && (_episodeLoading || _episodeCursor == null)) return;
    final slug = selectedSlug;
    if (slug == null || stopping || !loaded) return;
    final settled = Completer<void>();
    episodesSettled = settled;
    _episodeCancel?.cancel();
    final request = ++_episodeRequest;
    final token = _life.child();
    _episodeCancel = token;
    setState(() {
      _episodeLoading = true;
      _episodeError = null;
      if (!append) {
        episodes = [];
        _episodeCursor = null;
      }
    });
    try {
      final page = await client.episodes(
        slug,
        cursor: append ? _episodeCursor : null,
        cancel: token,
      );
      if (!mounted || request != _episodeRequest || stopping) return;
      final incoming = (page['episodes'] as List).cast<Map<String, dynamic>>();
      final next = page['next_cursor'] as String?;
      setState(() {
        final previous = append ? episodes : <Map<String, dynamic>>[];
        final ids = previous.map((row) => row['id']).toSet();
        episodes = [
          ...previous,
          ...incoming.where((row) => ids.add(row['id'])),
        ];
        _episodeError = append && next != null && next == _episodeCursor
            ? 'Could not load the next page. Reload the podcast to try again.'
            : null;
        _episodeCursor = _episodeError == null ? next : null;
      });
    } on OperationCancelled {
      // A newer selection or refresh owns the episode list.
    } catch (error) {
      if (mounted && request == _episodeRequest)
        setState(() => _episodeError = 'Could not load episodes. $error');
    } finally {
      if (mounted && request == _episodeRequest)
        setState(() => _episodeLoading = false);
      settled.complete();
    }
  }

  Future<void> importPlaylist() async {
    if (!loaded || importing || stopping) return;
    final settled = Completer<void>();
    importSettled = settled;
    late final String sourceUrl;
    try {
      sourceUrl = playlistSource(source.text);
    } catch (error) {
      setState(() => notice = _Notice(error.toString()));
      settled.complete();
      return;
    }
    final token = _life.child();
    _importCancel = token;
    String? createdSlug;
    setState(() {
      importing = true;
      notice = null;
    });
    try {
      final result = await client.importPlaylist(
        sourceUrl,
        importVideo ? 'video' : 'audio',
        cancel: token,
        onCreated: (show) {
          if (!mounted || stopping) return;
          final slug = _string(show, 'slug');
          createdSlug = slug;
          setState(() {
            catalog = Catalog(
              teams: catalog!.teams,
              importTeam: catalog!.importTeam,
              shows: [...catalog!.shows, show],
            );
            teamId = _string(show, 'team_id');
            selectedSlug = slug;
            importOpen = false;
            _jobs[slug] = token;
            _reports[slug] = 'Importing the first episodes…';
          });
        },
      );
      if (!mounted || stopping) return;
      setState(() {
        source.clear();
        selectedSlug = _string(result.show, 'slug');
        _reports[selectedSlug!] = _reportText(result.report);
      });
      unawaited(loadEpisodes());
    } catch (error) {
      if (!mounted || stopping) return;
      String? upgrade;
      if (error is PaymentRequired) {
        final importTeam = catalog?.importTeam;
        if (importTeam != null) {
          upgrade = client.upgradeUrl(importTeam);
          if (importVideo) upgrade = '$upgrade?family=video_hd';
        }
      }
      setState(() {
        if (createdSlug != null)
          _reports[createdSlug!] = 'Import stopped. Use Sync now to continue.';
        notice = error is SignInRequired
            ? const _Notice(
                'YouTube is asking you to sign in. Add fresh cookies in Settings, then use Sync now to continue this podcast.',
                signIn: true,
              )
            : _Notice(
                error is PaymentRequired
                    ? '${createdSlug == null ? 'Could not create podcast.' : 'Podcast created, but the import did not finish.'} ${error.message.isEmpty ? 'Payment is required to continue.' : error.message}'
                    : 'Import did not finish. $error',
                upgradeUrl: upgrade,
              );
      });
      unawaited(reload(preserveNotice: true));
    } finally {
      if (mounted)
        setState(() {
          importing = false;
          _importCancel = null;
          if (createdSlug != null) _jobs.remove(createdSlug);
        });
      settled.complete();
    }
  }

  Future<void> openSettings() async {
    if (settingsOpen || stopping) return;
    final settled = Completer<void>();
    settingsSettled = settled;
    cookieText.clear();
    setState(() {
      settingsOpen = true;
      importOpen = false;
      _cookieMessage = null;
      _cookieError = null;
      cookieBusy = true;
    });
    try {
      final saved = await client.cookieJar.isEnabled();
      if (mounted) setState(() => cookieSaved = saved);
    } catch (error) {
      if (mounted) setState(() => _cookieError = error.toString());
    } finally {
      if (mounted) setState(() => cookieBusy = false);
      settled.complete();
    }
  }

  Future<void> saveCookies({bool remove = false}) async {
    if (cookieBusy || stopping) return;
    final settled = Completer<void>();
    cookiesSettled = settled;
    setState(() {
      cookieBusy = true;
      _cookieMessage = null;
      _cookieError = null;
    });
    try {
      if (remove) {
        await client.cookieJar.remove();
      } else {
        await client.cookieJar.importText(cookieText.text);
      }
      if (!mounted) return;
      setState(() {
        cookieSaved = !remove;
        cookieText.clear();
        _cookieMessage = remove
            ? 'Cookies removed. Future requests will use anonymous access.'
            : 'Cookies saved. Return to your podcast and choose Sync now.';
      });
    } catch (error) {
      if (mounted) setState(() => _cookieError = error.toString());
    } finally {
      if (mounted) setState(() => cookieBusy = false);
      settled.complete();
    }
  }

  Future<void> _open(String raw) async {
    final url = Uri.parse(raw);
    if ((url.scheme != 'https' && url.scheme != 'http') || !url.hasAuthority) {
      throw FormatException('Invalid browser link: $raw');
    }
    if (browserOpener != null) {
      await browserOpener!(raw);
      return;
    }
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open $raw');
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS) {
      const MethodChannel('listenbox/native').setMethodCallHandler(null);
    }
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _life.cancel();
    _episodeCancel?.cancel();
    _downloadSubscription?.cancel();
    source.dispose();
    cookieText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _Palette(
      MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    );
    final theme = ThemeData(
      brightness: t.dark ? Brightness.dark : Brightness.light,
      useMaterial3: true,
      fontFamily: Platform.isMacOS ? '.SF NS Text' : null,
      scaffoldBackgroundColor: t.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: t.action,
        brightness: t.dark ? Brightness.dark : Brightness.light,
        surface: t.sheet,
        onSurface: t.ink,
        primary: t.action,
        onPrimary: Colors.white,
      ),
      textTheme: Theme.of(context).textTheme
          .apply(bodyColor: t.ink, displayColor: t.ink),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.ink,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.action,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          minimumSize: const Size(0, 36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: t.sheet,
        hintStyle: TextStyle(color: t.muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.border),
        ),
      ),
    );
    return MaterialApp(
      title: 'Listenbox',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        body: Stack(
          children: [
            Row(
              children: [
                SizedBox(width: 240, child: _sidebar(t)),
                Expanded(child: _mainPane(t)),
              ],
            ),
            if (stopping) _quitNotice(t),
          ],
        ),
      ),
    );
  }

  Widget _sidebar(_Palette t) {
    final scoped = shows
        .where((show) => teamId == null || show['team_id'] == teamId)
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: t.rail,
        border: Border(right: BorderSide(color: t.divider)),
      ),
      child: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.divider)),
            ),
            child: const Text(
              'Listenbox',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              children: [
                TextButton(
                  key: const Key('team-picker'),
                  onPressed: loaded
                      ? () => setState(() => teamPicker = !teamPicker)
                      : null,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size.fromHeight(36),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          teamId == null ? 'All teams' : _teamName(teamId),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: t.ink,
                          ),
                        ),
                      ),
                      Icon(
                        teamPicker
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 19,
                        color: t.muted,
                      ),
                    ],
                  ),
                ),
                if (teamPicker)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          _teamChoice(t, 'All teams', null),
                          for (final team
                              in catalog?.teams ??
                                  const <Map<String, dynamic>>[])
                            _teamChoice(
                              t,
                              _string(team, 'name'),
                              _string(team, 'id'),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('new-import'),
                  onPressed: loaded && !importing && !stopping
                      ? () => setState(() {
                          importOpen = true;
                          settingsOpen = false;
                          notice = null;
                        })
                      : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size.fromHeight(36),
                  ),
                  child: const Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Import playlist',
                          textAlign: TextAlign.left,
                        ),
                      ),
                      Icon(Icons.add, size: 18),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: const Key('podcasts'),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: scoped.isEmpty && loaded ? 1 : scoped.length,
              itemBuilder: (context, index) {
                if (scoped.isEmpty)
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Text(
                      'Your imported playlists will appear here.',
                      style: TextStyle(fontSize: 12, color: t.muted),
                    ),
                  );
                final show = scoped[index], slug = _string(show, 'slug');
                final status = _jobs.containsKey(slug)
                    ? 'Syncing'
                    : show['has_active_subscription'] == true
                    ? 'Automatic sync'
                    : 'Plan required';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Material(
                    color: !importOpen && selectedSlug == slug
                        ? t.selected
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      key: Key('show-$slug'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => selectShow(slug),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            _artwork(show['image_url'] as String?, 44, t),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _string(show, 'title'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    status,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: t.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'YouTube → Listenbox',
                style: TextStyle(fontSize: 12, color: t.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _teamChoice(_Palette t, String label, String? id) => TextButton(
    key: Key(id == null ? 'all-teams' : 'team-$id'),
    onPressed: () {
      setState(() {
        teamId = id;
        teamPicker = false;
      });
      final first = shows
          .where((show) => id == null || show['team_id'] == id)
          .firstOrNull;
      selectShow(first?['slug'] as String?);
    },
    style: TextButton.styleFrom(
      minimumSize: const Size.fromHeight(36),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.ink),
      ),
    ),
  );

  Widget _artwork(String? url, double size, _Palette t) => ClipRRect(
    borderRadius: BorderRadius.circular(size == 44 ? 8 : 14),
    child: SizedBox(
      width: size,
      height: size,
      child: url == null || url.isEmpty
          ? _artworkFallback(t)
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _artworkFallback(t),
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : _artworkFallback(t),
            ),
    ),
  );
  Widget _artworkFallback(_Palette t) => Container(
    color: t.selected,
    child: Icon(Icons.headphones, color: t.muted, size: 22),
  );

  Widget _mainPane(_Palette t) => Column(
    children: [
      Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.divider)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                settingsOpen ? 'Settings' : 'YouTube imports',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.muted,
                ),
              ),
            ),
            if (loaded)
              TextButton(
                key: const Key('reload'),
                onPressed: loading || stopping ? null : reload,
                child: const Text('Reload'),
              ),
            if (loaded) const SizedBox(width: 12),
            if (loaded)
              TextButton(
                key: const Key('settings'),
                onPressed: stopping ? null : openSettings,
                child: const Text('Settings'),
              ),
            const SizedBox(width: 12),
            TextButton(
              key: const Key('account'),
              onPressed: authenticating || stopping
                  ? null
                  : (loaded ? logout : login),
              child: Text(
                authenticating
                    ? 'Finish in your browser…'
                    : loaded
                    ? 'Log out'
                    : 'Sign in',
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          key: const Key('workspace-content'),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (notice != null && !settingsOpen) _errorNotice(t),
              if (settingsOpen)
                _settings(t)
              else if (importOpen)
                _importForm(t)
              else
                _detail(t),
              if (loaded && !settingsOpen && !importOpen) _episodeList(t),
              if (loaded && !settingsOpen) _transfers(t),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _errorNotice(_Palette t) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      key: const Key('error-notice'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(notice!.message, style: TextStyle(color: t.danger)),
        if (notice!.signIn)
          TextButton(
            key: const Key('youtube-sign-in-settings'),
            onPressed: openSettings,
            child: const Text('Open YouTube settings'),
          ),
        if (notice!.upgradeUrl != null)
          TextButton(
            key: const Key('upgrade-plan'),
            onPressed: () => _open(notice!.upgradeUrl!),
            child: const Text('Upgrade plan'),
          ),
      ],
    ),
  );

  Widget _importForm(_Palette t) {
    final team = _teamName(catalog?.importTeam);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Import a YouTube playlist',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              'Give your playlist a podcast home. Import it once, then keep new episodes coming with Listenbox.',
              style: TextStyle(fontSize: 14, color: t.muted),
            ),
            const SizedBox(height: 24),
            const Text(
              'Playlist URL',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('playlist-url'),
              controller: source,
              enabled: !importing && !stopping,
              decoration: const InputDecoration(
                hintText: 'https://www.youtube.com/playlist?list=…',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Use a public playlist. Its title becomes your podcast’s name.',
              style: TextStyle(fontSize: 12, color: t.muted),
            ),
            const SizedBox(height: 24),
            const Text(
              'Podcast format',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _formatChoice(t, 'Audio', Icons.headphones, false),
                const SizedBox(width: 8),
                _formatChoice(t, 'Video', Icons.videocam_outlined, true),
              ],
            ),
            const SizedBox(height: 24),
            Divider(color: t.divider),
            const SizedBox(height: 16),
            Text('Creates a new podcast in $team.'),
            const SizedBox(height: 8),
            Text(
              importVideo
                  ? 'A video plan with enough storage for the playlist is required. Playlist order is preserved. On later syncs, videos removed from the playlist are removed from the podcast.'
                  : 'A paid podcast plan is required. Playlist order is preserved. On later syncs, videos removed from the playlist are removed from the podcast.',
              style: TextStyle(fontSize: 12, color: t.muted),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  key: const Key('start-import'),
                  onPressed: importing || stopping ? null : importPlaylist,
                  child: Text(
                    importing
                        ? 'Checking playlist and plan…'
                        : 'Create podcast & import',
                  ),
                ),
                if (importing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (!importing && selectedShow != null)
                  TextButton(
                    key: const Key('cancel-import'),
                    onPressed: () => setState(() {
                      importOpen = false;
                      notice = null;
                    }),
                    child: const Text('Cancel'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _formatChoice(_Palette t, String label, IconData icon, bool video) {
    final selected = importVideo == video;
    return selected
        ? FilledButton(
            key: Key('import-${label.toLowerCase()}'),
            onPressed: importing || stopping
                ? null
                : () => setState(() => importVideo = video),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
          )
        : OutlinedButton(
            key: Key('import-${label.toLowerCase()}'),
            onPressed: importing || stopping
                ? null
                : () => setState(() => importVideo = video),
            style: OutlinedButton.styleFrom(
              foregroundColor: t.ink,
              side: BorderSide(color: t.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
          );
  }

  Widget _detail(_Palette t) {
    if (!loaded)
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your playlists. Your podcast.',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              Text(
                'Bring a public YouTube playlist to Listenbox, then keep your podcast in sync from this desktop.',
                style: TextStyle(color: t.muted),
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('welcome-sign-in'),
                onPressed: authenticating ? null : login,
                child: const Text('Sign in to Listenbox'),
              ),
            ],
          ),
        ),
      );
    final show = selectedShow;
    if (show == null)
      return Text(
        'Choose a podcast, or import your first playlist.',
        style: TextStyle(color: t.muted),
      );
    final youtube = show['youtube'] as Map<String, dynamic>;
    final sourceUrl = youtube['source_url'] as String;
    final slug = _string(show, 'slug');
    final running = _jobs.containsKey(slug);
    final active = show['has_active_subscription'] == true;
    final isPlaylist =
        Uri.tryParse(sourceUrl)?.queryParameters.containsKey('list') ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _artwork(show['image_url'] as String?, 120, t),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _string(show, 'title'),
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    show['source_kind'] == 'video'
                        ? 'Video podcast'
                        : 'Audio podcast',
                    style: TextStyle(color: t.muted),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    key: const Key('open-show'),
                    onPressed: () => _open(client.showUrl(show)),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.open_in_new, size: 16),
                        SizedBox(width: 6),
                        Text('Open in Listenbox'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Divider(color: t.divider),
        const SizedBox(height: 24),
        const Text(
          'YouTube source',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        TextButton(
          key: const Key('open-playlist'),
          onPressed: () => _open(sourceUrl),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.open_in_new, size: 16),
              const SizedBox(width: 8),
              Flexible(child: Text(sourceUrl, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          isPlaylist
              ? 'Episodes follow the playlist’s order. Removed videos leave this podcast on the next sync.'
              : 'This podcast imports a YouTube video. Sync again to resume unfinished transfers.',
          style: TextStyle(fontSize: 12, color: t.muted),
        ),
        if (!active)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Choose a paid audio or video plan to resume syncing.',
                ),
                TextButton(
                  key: const Key('choose-plan'),
                  onPressed: () =>
                      _open(client.upgradeUrl(_string(show, 'team_id'))),
                  child: const Text('Upgrade plan'),
                ),
              ],
            ),
          ),
        const SizedBox(height: 24),
        Row(
          children: [
            FilledButton(
              key: const Key('sync-now'),
              onPressed: active && !running && !stopping
                  ? () => syncShow(slug)
                  : null,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sync, size: 18),
                  SizedBox(width: 8),
                  Text('Sync now'),
                ],
              ),
            ),
            if (running) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                key: const Key('stop-sync'),
                onPressed: () => _jobs[slug]?.cancel(),
                child: const Text('Stop'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Text(
          _reports[slug] ??
              'Syncs automatically every hour while Listenbox is running.',
          key: const Key('sync-status'),
          style: TextStyle(color: t.muted),
        ),
      ],
    );
  }

  Widget _episodeList(_Palette t) {
    if (selectedShow == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: t.divider),
          const SizedBox(height: 24),
          const Text(
            'Episodes',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          for (final episode in episodes)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.divider)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_string(episode, 'title')),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (episode['duration_seconds'] case final int duration
                          when duration > 0)
                        _duration(duration),
                      episode['status'] == 'published' ? 'Published' : 'Draft',
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: t.muted),
                  ),
                ],
              ),
            ),
          if (_episodeLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Loading episodes…',
                style: TextStyle(color: t.muted),
              ),
            ),
          if (!_episodeLoading && _episodeError != null) ...[
            Text(_episodeError!, style: TextStyle(color: t.danger)),
            TextButton(
              key: const Key('retry-episodes'),
              onPressed: loadEpisodes,
              child: const Text('Reload episodes'),
            ),
          ],
          if (!_episodeLoading && _episodeError == null && episodes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No episodes synced yet.',
                style: TextStyle(color: t.muted),
              ),
            ),
          if (_episodeCursor != null)
            TextButton(
              key: const Key('more-episodes'),
              onPressed: _episodeLoading
                  ? null
                  : () => loadEpisodes(append: true),
              child: const Text('Load more episodes'),
            ),
        ],
      ),
    );
  }

  String _duration(int seconds) => seconds >= 3600
      ? '${seconds ~/ 3600}:${((seconds ~/ 60) % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  Widget _transfers(_Palette t) {
    final transfers =
        progress?.items.reversed.take(100).toList() ?? const <Download>[];
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: t.divider),
          const SizedBox(height: 24),
          const Text(
            'Transfers',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          if (transfers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'New episodes will appear here as they sync.',
                style: TextStyle(color: t.muted),
              ),
            ),
          for (final item in transfers)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.divider)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.title),
                            const SizedBox(height: 4),
                            Text(
                              item.durationSeconds == null
                                  ? item.sourceTitle
                                  : '${item.sourceTitle} · ${_duration(item.durationSeconds!)}',
                              style: TextStyle(fontSize: 12, color: t.muted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        _phase(item.phase),
                        style: TextStyle(
                          color: item.phase == Phase.failed
                              ? t.danger
                              : t.muted,
                        ),
                      ),
                    ],
                  ),
                  if (item.phase == Phase.downloading && item.total > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: (item.received / item.total).clamp(0, 1),
                      backgroundColor: t.selected,
                      color: t.action,
                      minHeight: 5,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${(item.received / 1000000).toStringAsFixed(1)} / ${(item.total / 1000000).toStringAsFixed(1)} MB',
                      style: TextStyle(fontSize: 12, color: t.muted),
                    ),
                  ],
                  if (item.reason != null)
                    Text(item.reason!, style: TextStyle(color: t.muted)),
                  if (item.error != null)
                    Text(item.error!, style: TextStyle(color: t.danger)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _phase(Phase phase) => switch (phase) {
    Phase.queued => 'Queued',
    Phase.resolving => 'Reading source',
    Phase.downloading => 'Downloading',
    Phase.preparing => 'Preparing media',
    Phase.uploading => 'Uploading',
    Phase.complete => 'Complete',
    Phase.skipped => 'Skipped',
    Phase.failed => 'Failed',
  };

  Widget _settings(_Palette t) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 720),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Settings',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
              ),
            ),
            TextButton(
              key: const Key('close-settings'),
              onPressed: cookieBusy
                  ? null
                  : () => setState(() {
                      settingsOpen = false;
                      cookieText.clear();
                    }),
              child: const Text('Done'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'YouTube',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'If YouTube asks you to sign in, add cookies from a private browser session to continue importing.',
        ),
        const SizedBox(height: 8),
        Text(
          'Cookies stay on this computer and are shared with the Listenbox CLI. Keep them private, like a password.',
          style: TextStyle(color: t.muted),
        ),
        TextButton(
          key: const Key('cookie-guide'),
          onPressed: () => _open(youtubeCookieGuideUrl),
          child: const Text('How to export YouTube cookies'),
        ),
        const SizedBox(height: 24),
        const Text(
          'YouTube cookies',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          cookieSaved
              ? 'A session is saved. Pasting a new export replaces it.'
              : 'Paste a Netscape cookies.txt export, including the header line.',
          style: TextStyle(color: t.muted),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('cookie-export'),
          controller: cookieText,
          enabled: !cookieBusy && !stopping,
          maxLines: 6,
          minLines: 6,
          decoration: const InputDecoration(
            hintText: 'Paste the complete Netscape cookies.txt export here',
          ),
        ),
        if (_cookieError != null)
          Text(_cookieError!, style: TextStyle(color: t.danger)),
        if (_cookieMessage != null) Text(_cookieMessage!),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          children: [
            FilledButton(
              key: const Key('save-cookies'),
              onPressed: cookieBusy || stopping ? null : saveCookies,
              child: Text(cookieBusy ? 'Please wait…' : 'Save cookies'),
            ),
            TextButton(
              key: const Key('remove-cookies'),
              onPressed: cookieBusy || stopping || !cookieSaved
                  ? null
                  : () => saveCookies(remove: true),
              child: const Text('Remove cookies'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _quitNotice(_Palette t) => IgnorePointer(
    child: Center(
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: t.action.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Saving progress',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
            SizedBox(height: 12),
            Text(
              'Finishing current work…',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    ),
  );
}
