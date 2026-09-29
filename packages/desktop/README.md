# Listenbox desktop

The Flutter desktop interface uses the shared `listenbox_sync_engine` client for
profiles, authentication, imports, downloads, and synchronization.

Start a standard Flutter session from this directory:

```sh
flutter run -d macos
```

Use `windows` or `linux` on those hosts. Debug sessions load
`../../config/dev.yaml`; set `LISTENBOX_CONFIG` to use another config file.
Press `r` to hot reload Dart edits, or use the repository's VS Code launch
configuration for reload on save. The shared client and admitted work survive
hot reload.

From the client repository root, `moon run desktop:build` creates the release
bundle and `moon run desktop:test-e2e` runs the native Flutter integration suite.

See [the development guide](../../docs/DEVELOPMENT.md) for toolchain and native
asset details.
