# Dart/Flutter client cutover

## Behavior and boundaries

Port the existing Rust client to four Dart packages: `client_youtubei`,
`listenbox_sync_engine`, `listenbox_cli`, and `listenbox_desktop`. The desktop
preserves the established application layout and native interactions. The CLI
preserves the public command/protocol behavior exercised by API E2E. Application
state is owned by one Dart isolate per process; async downloads and queued writes
do not introduce shared application-state threads.

`youtubei` owns the embedded QuickJS host and pinned YouTube.js bundle. The sync
engine owns API/config contracts, authorization, cookie transport, validated source
enumeration, format selection, range downloads, SQLite checkpoints, media
preparation, package uploads, source reconciliation, and scan scheduling. CLI and
desktop call the same engine. The API continues to own remote admission, published
episodes, object ownership, and cleanup. The SQLite journal owns local resumable
work, while progress events are projections only.

## Native and build contracts

Use pinned prebuilt SQLite, QuickJS, and FFmpeg artifacts in each release bundle.
Build hooks verify native artifacts and register them with Dart code assets. The
runtime must not depend on system installations of these libraries. Native source
builds belong in deliberate artifact publishing jobs, outside normal dev/PR builds.
The YouTube.js repository stays a nested submodule with the existing pinned source
revision initially. Bundle names must be preserved for its parser.

Moon launches Flutter directly for development, retaining terminal input and a
single running application session. Shared Dart edits use Flutter hot reload.
The youtubei build hook bundles its pinned YouTube.js source and embeds the
result in a small generated Rust resource library. This cached resource has no
application policy, and Dart-only edits do not rebuild it. Source and native
library changes require a full restart. Normal builds never compile the large
QuickJS, SQLite, or FFmpeg libraries.
Moon targets must declare all code generation, bundle, package-resolution, and
native artifact prerequisites, including on absent-artifact/cold-cache startup.
The parent API E2E build copies the complete Dart CLI bundle, not just its executable.
Oasmith emits the public Dart client from public.responsible.ts through
openapi:generate-public-dart-client. The shared transport supplies authorization,
tracing, proxy routing, bounded responses, and cancellation to generated
operations; endpoint paths and public DTOs are owned by the generator. Generated
source is committed for standalone client development.

## Failure and ownership walkthrough

- Downloads persist completed ranges only after bytes and hashes are durable;
  interrupted ranges resume through the same manager. Source/format changes
  invalidate only the affected owned download records.
- Prepared media and its complete manifest remain durable across a lost admission
  acknowledgement. Re-entry uses the operation identity and existing package.
- Upload completion checkpoints survive successful remote writes with lost
  acknowledgements; the API's idempotent operation contract remains authoritative.
- Failed/incomplete source enumeration never authorizes deletion. Authentication
  errors remain errors, while explicitly unavailable items remain distinguishable.
- Cancellation stops admission and awaits owned operations. Logout removes shared
  credentials only after draining, preventing an in-flight login restoring them.
- Cross-process SQLite initialization is serialized; WAL readers can observe
  committed state while a write transaction is active. Durable writes retain the
  existing explicit fsync settings.

## Acceptance proof

Reuse the integrated cases in apps/api/e2e/cli*_test.go and client*_test.go against
the compiled Dart CLI. API E2E does not build or launch the desktop. Preserve real native media
processing and real embedded YouTube.js against test-local provider responses.
Retain assertions on protocol outcomes, durable API/SQLite state, range requests,
owned media outputs, absence of duplicate publication, and actual process closure.
Desktop control scenarios live in the desktop package and run Flutter with the
shared Dart client against local HTTP fixtures. Tests establish their intended states through explicit gates,
finish below ten seconds, and retain the hard thirty-second failure guard.

Verification targets: client package analysis, cli:build, desktop:build,
desktop:test-e2e, focused api:test-e2e CLI/client regressions, then the complete
affected integrated group. Inspect the resolved Moon action graph and exercise
an isolated cold startup. Verify packaged CLI native operations outside source
checkout paths, and inspect a Flutter hot-reload session with retained state.
Local macOS verification cannot establish Windows/Linux execution; those require
their native runners and must be reported accurately. Do not poll CI.
