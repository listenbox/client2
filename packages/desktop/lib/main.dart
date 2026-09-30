import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:listenbox_sync_engine/sync_engine.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_host.dart';
import 'design_tokens.dart';
import 'theme.dart';

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
  const ListenboxDesktop({
    super.key,
    required this.client,
    this.host = const NativeDesktopHost(),
  });
  final Client client;
  final DesktopHost host;
  @override
  State<ListenboxDesktop> createState() => DesktopWorkspaceState();
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
  List<Download> _sourceItems = [];
  bool _showIssues = false;
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
  Future<void>? windowHiddenSettled;
  Future<void>? windowOpenSettled;
  Future<void> Function(String)? browserOpener;

  Client get client => widget.client;
  DesktopHost get host => widget.host;
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
    host.attach(this, this, quit);
    progress = client.downloads.snapshot();
    _downloadSubscription = client.downloads.changes.listen((value) {
      if (mounted) setState(() => progress = value);
    });
    unawaited(_installTray());
    if (client.hasCredentials) initialLoad = reload();
  }

  Future<void> _installTray() async {
    try {
      await host.installTray(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Open Listenbox'),
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
    windowHiddenSettled = host.hideWindow();
  }

  @override
  void onTrayIconMouseDown() {
    if (host.platform == DesktopPlatform.macOS) {
      unawaited(host.popUpTrayMenu());
    } else if (host.platform == DesktopPlatform.windows) {
      _requestOpenWindow();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (host.platform == DesktopPlatform.macOS ||
        host.platform == DesktopPlatform.windows) {
      unawaited(host.popUpTrayMenu());
    }
  }

  void _requestOpenWindow() {
    windowOpenSettled = _openWindow();
  }

  Future<void> _openWindow() async {
    await host.openWindow();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'show') _requestOpenWindow();
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
      if (_trayInstalled) await host.destroyTray();
      host.exitProcess(0);
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
      if (mounted && !stopping && selectedSlug == slug)
        unawaited(loadEpisodes());
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
      _sourceItems = [];
      _showIssues = false;
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
      final sourceItems = await client.syncItems(slug, cancel: token);
      if (!mounted || request != _episodeRequest || stopping) return;
      final incoming = (page['episodes'] as List).cast<Map<String, dynamic>>();
      final next = page['next_cursor'] as String?;
      setState(() {
        final previous = append ? episodes : <Map<String, dynamic>>[];
        final ids = previous.map((row) => row['id']).toSet();
        _sourceItems = sourceItems;
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
    host.detach(this, this);
    _life.cancel();
    _episodeCancel?.cancel();
    _downloadSubscription?.cancel();
    source.dispose();
    cookieText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ListenboxTheme(
      MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    );
    return MaterialApp(
      title: 'Listenbox',
      debugShowCheckedModeBanner: false,
      theme: const ListenboxTheme(false).data,
      darkTheme: const ListenboxTheme(true).data,
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

  Widget _sidebar(ListenboxTheme t) {
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
            child: Text('Listenbox', style: t.label),
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
                    minimumSize: const Size.fromHeight(
                      DesignTokens.buttonPrimaryHeight,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          teamId == null ? 'All teams' : _teamName(teamId),
                          overflow: TextOverflow.ellipsis,
                          style: t.title,
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
                    minimumSize: const Size.fromHeight(
                      DesignTokens.buttonPrimaryHeight,
                    ),
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
                      style: t.meta,
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
                        : t.sheet.withValues(alpha: 0),
                    borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
                    child: InkWell(
                      key: Key('show-$slug'),
                      borderRadius: BorderRadius.circular(
                        DesignTokens.radiusMd,
                      ),
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
                                    style: t.label,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(status, style: t.meta),
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
              child: Text('YouTube → Listenbox', style: t.meta),
            ),
          ),
        ],
      ),
    );
  }

  Widget _teamChoice(ListenboxTheme t, String label, String? id) => TextButton(
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
      minimumSize: const Size.fromHeight(DesignTokens.buttonPrimaryHeight),
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

  Widget _artwork(String? url, double size, ListenboxTheme t) {
    final imageUrl = url?.trim();
    final uri = imageUrl == null ? null : Uri.tryParse(imageUrl);
    final validUrl =
        uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
    final decodeSize = (size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 512);
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        size == 44 ? DesignTokens.radiusIcon : DesignTokens.radiusMedia,
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: !validUrl
            ? _artworkFallback(t)
            : Image(
                image: ResizeImage(
                  NetworkImage(imageUrl!),
                  width: decodeSize,
                  height: decodeSize,
                  policy: ResizeImagePolicy.fit,
                ),
                width: size,
                height: size,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                loadingBuilder: (_, image, progress) =>
                    progress == null ? image : _artworkFallback(t),
                errorBuilder: (_, _, _) => _artworkFallback(t),
              ),
      ),
    );
  }

  Widget _artworkFallback(ListenboxTheme t) => Container(
    color: t.selected,
    child: Icon(Icons.headphones, color: t.muted, size: 22),
  );

  Widget _mainPane(ListenboxTheme t) {
    final rows = _rows;
    final visible = rows.where((row) => row.issue == _showIssues).toList();
    return Column(
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.label.copyWith(color: t.muted),
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
          child: CustomScrollView(
            key: const Key('workspace-content'),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(DesignTokens.spaceXl),
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
                      if (loaded &&
                          !settingsOpen &&
                          !importOpen &&
                          selectedShow != null)
                        _episodeHeader(t, rows),
                    ],
                  ),
                ),
              ),
              if (loaded &&
                  !settingsOpen &&
                  !importOpen &&
                  selectedShow != null) ...[
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DesignTokens.spaceXl,
                  ),
                  sliver: SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) =>
                        _episodeRow(visible[index], t),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(DesignTokens.spaceXl),
                    child: _episodeFooter(t, visible),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _errorNotice(ListenboxTheme t) => Padding(
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

  Widget _importForm(ListenboxTheme t) {
    final team = _teamName(catalog?.importTeam);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Import a YouTube playlist', style: t.pageTitle),
            const SizedBox(height: 12),
            Text(
              'Give your playlist a podcast home. Import it once, then keep new episodes coming with Listenbox.',
              style: t.meta,
            ),
            const SizedBox(height: 24),
            Text('Playlist URL', style: t.label),
            const SizedBox(height: 8),
            TextField(
              style: t.field,
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
              style: t.meta,
            ),
            const SizedBox(height: 24),
            Text('Podcast format', style: t.label),
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
              style: t.meta,
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

  Widget _formatChoice(
    ListenboxTheme t,
    String label,
    IconData icon,
    bool video,
  ) {
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
                borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
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

  Widget _detail(ListenboxTheme t) {
    if (!loaded)
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your playlists. Your podcast.', style: t.pageTitle),
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
                  Text(_string(show, 'title'), style: t.pageTitle),
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
        Text('YouTube source', style: t.title),
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
          style: t.meta,
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

  List<_EpisodeRow> get _rows {
    final slug = selectedSlug;
    final sources = {for (final item in _sourceItems) item.sourceUrl: item};
    final live = <String>{};
    for (final item in progress?.items ?? const <Download>[]) {
      if (item.sourceId == slug) {
        sources[item.sourceUrl] = item;
        live.add(item.sourceUrl);
      }
    }
    final published = {
      for (final episode in episodes)
        if (episode['source_url'] is String) episode['source_url'] as String,
    };
    final result = [
      for (final (index, episode) in episodes.indexed)
        _EpisodeRow(
          order: index,
          episode: episode,
          item: sources[episode['source_url']],
        ),
      for (final item in sources.values)
        if (!published.contains(item.sourceUrl) &&
            (item.phase != Phase.complete || live.contains(item.sourceUrl)))
          _EpisodeRow(item: item, order: episodes.length),
    ];
    result.sort((a, b) {
      final position = a.position.compareTo(b.position);
      return position != 0 ? position : a.order.compareTo(b.order);
    });
    return result;
  }

  Widget _episodeHeader(ListenboxTheme t, List<_EpisodeRow> rows) {
    final missing = rows.where((row) => row.issue).length;
    final published = episodes
        .where((episode) => episode['status'] == 'published')
        .length;
    return Padding(
      padding: const EdgeInsets.only(top: DesignTokens.spaceXl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: t.divider),
          const SizedBox(height: DesignTokens.spaceXl),
          Text(
            '${_episodeCursor == null ? '$published in RSS' : '${episodes.length} episodes loaded'} · $missing not imported',
            key: const Key('episode-summary'),
            style: t.supporting,
          ),
          const SizedBox(height: DesignTokens.spaceMd),
          Wrap(
            spacing: DesignTokens.spaceSm,
            runSpacing: DesignTokens.spaceSm,
            children: [
              _episodeFilter(t, false, 'Episodes'),
              _episodeFilter(t, true, 'Not imported ($missing)'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _episodeFilter(ListenboxTheme t, bool issues, String label) =>
      Semantics(
        selected: _showIssues == issues,
        child: TextButton(
          key: Key(issues ? 'filter-not-imported' : 'filter-episodes'),
          onPressed: () => setState(() => _showIssues = issues),
          style: TextButton.styleFrom(
            backgroundColor: _showIssues == issues ? t.selected : null,
          ),
          child: Text(label),
        ),
      );

  Widget _episodeRow(_EpisodeRow row, ListenboxTheme t) {
    final item = row.item;
    final episode = row.episode;
    final status = episode != null
        ? (episode['status'] == 'published' ? 'Published' : 'Draft')
        : item!.phase == Phase.queued && !_jobs.containsKey(selectedSlug)
        ? 'Waiting for sync'
        : _phase(item.phase);
    final duration =
        episode?['duration_seconds'] as int? ?? item?.durationSeconds;
    return Container(
      key: Key('episode-row-${episode?['id'] ?? item!.id}'),
      padding: const EdgeInsets.symmetric(vertical: DesignTokens.spaceLg),
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
                    Text(
                      episode?['title'] as String? ?? item!.title,
                      style: t.body,
                    ),
                    if (duration != null && duration > 0) ...[
                      const SizedBox(height: DesignTokens.spaceXs),
                      Text(_duration(duration), style: t.meta),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: DesignTokens.spaceLg),
              Text(
                status,
                style: t.meta.copyWith(color: row.issue ? t.danger : t.muted),
              ),
            ],
          ),
          if (episode == null &&
              item!.phase == Phase.downloading &&
              item.total > 0) ...[
            const SizedBox(height: DesignTokens.spaceSm),
            LinearProgressIndicator(
              value: (item.received / item.total).clamp(0, 1),
              semanticsLabel: 'Downloading ${item.title}',
              semanticsValue:
                  '${(item.received / item.total * 100).round().clamp(0, 100)}',
              minHeight: DesignTokens.spaceXs,
            ),
            const SizedBox(height: DesignTokens.spaceXs),
            Text(
              '${(item.received / 1000000).toStringAsFixed(1)} / ${(item.total / 1000000).toStringAsFixed(1)} MB',
              style: t.meta,
            ),
          ],
          if (row.issue) ...[
            const SizedBox(height: DesignTokens.spaceSm),
            Text(
              item!.reason ?? item.error ?? 'Import did not finish.',
              style: t.body,
            ),
            const SizedBox(height: DesignTokens.spaceXs),
            TextButton.icon(
              key: Key('open-source-${item.id}'),
              onPressed: () => _open(item.sourceUrl),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open on YouTube'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _episodeFooter(ListenboxTheme t, List<_EpisodeRow> visible) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_episodeLoading) Text('Loading episodes…', style: t.supporting),
      if (!_episodeLoading && _episodeError != null) ...[
        Text(_episodeError!, style: t.body.copyWith(color: t.danger)),
        TextButton(
          key: const Key('retry-episodes'),
          onPressed: loadEpisodes,
          child: const Text('Reload episodes'),
        ),
      ],
      if (!_episodeLoading && _episodeError == null && visible.isEmpty)
        Text(
          _showIssues ? 'No import issues.' : 'No episodes synced yet.',
          style: t.supporting,
        ),
      if (_showIssues && visible.isNotEmpty)
        Text(
          'Sync again after resolving the source issues.',
          style: t.supporting,
        ),
      if (!_showIssues && _episodeCursor != null)
        TextButton(
          key: const Key('more-episodes'),
          onPressed: _episodeLoading ? null : () => loadEpisodes(append: true),
          child: const Text('Load more episodes'),
        ),
    ],
  );

  String _duration(int seconds) => seconds >= 3600
      ? '${seconds ~/ 3600}:${((seconds ~/ 60) % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  String _phase(Phase phase) => switch (phase) {
    Phase.queued => 'Queued',
    Phase.resolving => 'Reading source',
    Phase.downloading => 'Downloading',
    Phase.preparing => 'Preparing media',
    Phase.uploading => 'Uploading',
    Phase.complete => 'Published',
    Phase.skipped => 'Unavailable',
    Phase.failed => 'Import failed',
  };

  Widget _settings(ListenboxTheme t) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 720),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Settings', style: t.pageTitle)),
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
        Text('YouTube', style: t.title),
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
        Text('YouTube cookies', style: t.label),
        const SizedBox(height: 8),
        Text(
          cookieSaved
              ? 'A session is saved. Pasting a new export replaces it.'
              : 'Paste a Netscape cookies.txt export, including the header line.',
          style: TextStyle(color: t.muted),
        ),
        const SizedBox(height: 8),
        TextField(
          style: t.field,
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

  Widget _quitNotice(ListenboxTheme t) => IgnorePointer(
    child: Center(
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: t.action.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(DesignTokens.radiusPanel),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Saving progress', style: t.title.copyWith(color: t.onAction)),
            SizedBox(height: 12),
            Text(
              'Finishing current work…',
              style: t.body.copyWith(color: t.onAction),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EpisodeRow {
  const _EpisodeRow({this.episode, this.item, required this.order});
  final int order;
  final Map<String, dynamic>? episode;
  final Download? item;
  bool get issue =>
      episode == null &&
      (item?.phase == Phase.skipped || item?.phase == Phase.failed);
  int get position =>
      item?.position ??
      episode?['source_position'] as int? ??
      0x7fffffffffffffff;
}
