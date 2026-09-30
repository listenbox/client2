# Dart and Flutter client

- The four application modules are `packages/youtubei`, `packages/sync-engine`,
  `packages/cli`, and `packages/desktop`.
- All application logic is Dart. Desktop is Flutter; CLI is standalone Dart.
- One Dart isolate owns each process's application state. Use async operations
  and explicit admission queues; native execution details stay inside libraries.
- Shared HTTP, profiles, credentials, cookies, persistence, download management,
  media preparation, and synchronization belong in sync-engine.
- Embed the pinned YouTube.js submodule through youtubei. Never invoke a Node
  subprocess or the superseded Rust client at runtime.
- Import the pinned upstream `package:fjs/fjs.dart`; do not copy its Dart
  bindings or fork its runtime. Accept the QuickJS version shipped with FJS
  and upgrade the Dart package and matching native artifacts together.
- CLI and desktop must independently bundle pinned SQLite, QuickJS, and FFmpeg
  libraries. Normal builds consume verified prebuilt artifacts, never silently
  fall back to compiling native dependencies or loading system versions.
- The youtubei hook may compile a tiny generated Rust resource library that only
  exposes the pinned YouTube.js bundle bytes to Dart 3.13/Flutter 3.47 native
  assets. It must not compile the FJS/QuickJS runtime or application logic.
  Dart and Flutter data assets are not supported on the stable SDK in use.
- A YouTube.js source or native artifact change requires a full Flutter
  restart; ordinary Dart UI changes keep the hot-reload session and must not
  rebuild the YouTube.js resource library.
- Preserve resumable work and acknowledgement-loss safety. Cancellation must
  settle owned work before logout or exit; UI progress is never durable truth.
- Use the parent repository's integrated API E2E suites for the real Dart CLI.
  Keep integrated Flutter UI coverage headless in `packages/desktop/test` with
  the real shared client and local HTTP fixtures. Tests must not open or focus
  a native window. The API E2E suite must not launch or build the desktop app.
- Desktop development uses Flutter's ordinary run/hot-reload session.
- Do not add unit tests or compatibility paths for the superseded Rust client.
