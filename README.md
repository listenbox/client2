# Listenbox client

The Listenbox desktop app and command-line client are a Dart workspace. The
desktop app uses Flutter; the CLI runs as a standalone Dart executable. Both use
the same synchronization engine and an embedded, pinned YouTube.js runtime.
Each process keeps application state in one Dart isolate; the small Rust asset
only carries bundled JavaScript bytes.

| Package | Responsibility |
| --- | --- |
| `packages/youtubei` | Embedded YouTube.js and QuickJS host |
| `packages/sync-engine` | Profiles, API access, SQLite journal, downloads, media, and synchronization |
| `packages/cli` | Terminal commands and protocol output |
| `packages/desktop` | Flutter desktop interface |

## Get started

Install Flutter **3.47.5** (Dart **3.13.4**), Rust **1.98.1**, Moon
**2.5.5**, and the [prebuilt Kache **0.27.0** executable](https://github.com/kunobi-ninja/kache/releases/tag/v0.27.0)
for your host, then clone with submodules:

```sh
git clone --recurse-submodules https://github.com/listenbox/client2.git
cd client2
flutter pub get --enforce-lockfile
moon run cli:build
moon run desktop:build
```

The CLI bundle is `packages/cli/dist/release/bundle/`; launch its `bin/listenbox`
executable (`bin/listenbox.exe` on Windows) from that complete bundle. The
desktop release bundle is `packages/desktop/dist/release/`. Keep each complete
bundle together so its verified native libraries remain available.

For development, run Flutter directly from `packages/desktop`:

```sh
cd packages/desktop
flutter run -d macos
```

Use `-d windows` or `-d linux` on those hosts. Debug sessions load
`config/dev.yaml` for the parent repository's local API and dashboard.
`moon run desktop:dev` and the included VS Code launch use that same config.
Save a Dart file in that VS Code session to hot reload; in a terminal Flutter
session, press `r` to reload or `R` to restart. See
[the development guide](docs/DEVELOPMENT.md) for setup and build details.

Build hooks verify and bundle pinned SQLite, QuickJS, and FFmpeg libraries.
The youtubei hook bundles pinned `vendor/youtubejs` source and compiles a small
Rust resource containing its bytes. Normal builds need neither Node.js nor
Aube, and never compile the larger native libraries from source. Kache caches
the resource compilation in a shared OS-level store across checkouts.
