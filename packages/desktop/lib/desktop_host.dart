import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

enum DesktopPlatform { macOS, windows, linux }

/// The operating-system boundary for the persistent desktop workspace.
abstract class DesktopHost {
  DesktopPlatform get platform;

  void attach(
    WindowListener windowListener,
    TrayListener trayListener,
    Future<void> Function() requestQuit,
  );

  void detach(WindowListener windowListener, TrayListener trayListener);
  Future<void> installTray(Menu menu);
  Future<void> hideWindow();
  Future<void> openWindow();
  Future<void> popUpTrayMenu();
  Future<void> destroyTray();
  void exitProcess(int code);
}

class NativeDesktopHost implements DesktopHost {
  const NativeDesktopHost();

  @override
  DesktopPlatform get platform => Platform.isMacOS
      ? DesktopPlatform.macOS
      : Platform.isWindows
      ? DesktopPlatform.windows
      : DesktopPlatform.linux;

  @override
  void attach(
    WindowListener windowListener,
    TrayListener trayListener,
    Future<void> Function() requestQuit,
  ) {
    if (platform == DesktopPlatform.macOS) {
      const MethodChannel('listenbox/native')
          .setMethodCallHandler((call) async {
            if (call.method == 'quitRequested') await requestQuit();
          });
    }
    windowManager.addListener(windowListener);
    trayManager.addListener(trayListener);
  }

  @override
  void detach(WindowListener windowListener, TrayListener trayListener) {
    if (platform == DesktopPlatform.macOS) {
      const MethodChannel('listenbox/native').setMethodCallHandler(null);
    }
    windowManager.removeListener(windowListener);
    trayManager.removeListener(trayListener);
  }

  @override
  Future<void> installTray(Menu menu) async {
    // Match the Rust client's tray.svg renders; the Windows ICO embeds its
    // tray-windows.png bytes for Win32 LoadImage.
    final asset = switch (platform) {
      DesktopPlatform.macOS => 'assets/tray-macos.png',
      DesktopPlatform.windows => 'assets/tray-windows.ico',
      DesktopPlatform.linux => 'assets/tray.png',
    };
    await trayManager.setIcon(
      asset,
      isTemplate: platform == DesktopPlatform.macOS,
    );
    await trayManager.setToolTip('Listenbox — YouTube to podcast sync');
    await trayManager.setContextMenu(menu);
  }

  @override
  Future<void> hideWindow() => windowManager.hide();

  @override
  Future<void> openWindow() async {
    // window_manager.show restores a minimized window before showing it.
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> popUpTrayMenu() => trayManager.popUpContextMenu();

  @override
  Future<void> destroyTray() => trayManager.destroy();

  @override
  void exitProcess(int code) => exit(code);
}
