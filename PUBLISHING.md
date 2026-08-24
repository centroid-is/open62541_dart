# Publishing `open62541` to pub.dev

This document records the current publishability assessment for the `open62541`
package and a concrete checklist for publishing when ready. It was produced on
2026-08-24 against package version `1.5.6-1`.

Local toolchain used for these checks: **Dart 3.10.1** (stable). The CI/pub
formatter uses Dart 3.13; formatting under 3.13 could not be verified locally
(see caveats).

---

## 1. `dart pub publish --dry-run` result

The dry-run **passes**. After the changes in this branch the only remaining
warning is the expected "publish from a clean git state" notice, which
disappears once the prep changes are committed.

- Total compressed archive size: **~256 KB** — far below pub.dev limits
  (~100 MB gzip recommended / 256 MB uncompressed). The native sources are
  downloaded at build time, not vendored, which keeps the archive small.
- The 2 MB generated bindings file (`lib/src/third_party/open62541.g.dart`) is
  included and compresses well.
- Before the fixes, the dry-run reported one hard warning: *"Please add a
  `CHANGELOG.md`"* — now resolved.

## 2. pana score

`pana --no-warning .` (pana 0.23.12).

| Before | After |
|-------:|------:|
| **135 / 160** | **160 / 160** |

What changed:

| Category | Before | After | Fix |
|---|---|---|---|
| Valid `pubspec.yaml` | 0/10 | 10/10 | Lengthened `description` to the 50–180 char range |
| Valid `CHANGELOG.md` | 0/5 | 5/5 | Added `CHANGELOG.md` |
| Package has an example | 0/10 | 10/10 | Added `example/example.dart` + `example/README.md` |
| Valid `README.md` | 5/5 | 5/5 | (Rewrote into a user-facing README anyway) |
| Static analysis | 50/50 | 50/50 | Already clean |
| Platform support | 20/20 | 20/20 | 5/6 platforms (no Web — expected for native FFI) |
| Dependencies | 40/40 | 40/40 | See the standing risk below |

### Standing pana risk (not fixed here, needs a decision)

pana warns:

> The constraint `^1.0.0` on `code_assets` does not support the stable version
> `2.0.0` … When `code_assets` is 30 days old, this package will no longer be
> awarded points in this category.

`code_assets 2.0.0` was published ~2026-08-18, so from roughly **2026-09-17**
this package will drop **10 pub points** (dependencies category) unless the
constraint is widened. `hooks` has likewise moved to `2.x`.

**Why it was not bumped automatically:** `code_assets`/`hooks` going `1.x → 2.x`
can carry breaking API changes to the `hook/build.dart` code, and the native
build (network download + CMake compile of open62541 and mbedTLS) **cannot be
exercised in this environment**. Bumping a native-build dependency without
running a real build is risky. Treat this as a pre-publish task: bump, then
verify an actual `dart run`/native build on each target platform (see checklist).

## 3. Native build hooks — can this be published to pub.dev? (the hard question)

**Verdict: YES — publishable today. The build-hooks / code-assets mechanism is a
stable, shipping Dart feature, not experimental.** There is direct precedent on
pub.dev. There are, however, real caveats specific to *this* package.

### What works today

- **Build hooks are stable as of Dart 3.10** (released 2026-11-12 / announced
  with Flutter 3.38). Anthropic-independent sources: the Dart 3.10 announcement
  states "Build hooks: Now stable!" Link hooks + tree-shaking of native assets
  became stable in Dart 3.13.
- **`dart pub publish` accepts `hook/build.dart`** as ordinary package content.
  The dry-run here confirms it is packaged with no hook-specific complaint.
- **pana scores such packages normally.** Scoring is based on *static analysis*
  (import graph + `dart analyze`), and this package reaches 160/160.
- **Real precedent:** `sqlite3` v3.x on pub.dev uses build hooks + code assets to
  bundle SQLite and scores 150 pub points with all platform tags. Companion
  package `sqlite3_native_assets` also exists. First-party `dart-lang/native`
  ships hook examples including **`download_asset`**, which downloads a prebuilt
  asset in the build hook — i.e. downloading at build time is an officially
  demonstrated pattern.
- **Consumers need NO experiment flag** on current toolchains. The old
  `--enable-experiment=native-assets` requirement is gone for **Dart ≥ 3.10**;
  in Flutter, native assets are **enabled by default from Flutter 3.38**.
- **Downloading sources at build time is permitted.** No pub.dev policy forbids
  network access in build hooks; the hook environment even forwards
  `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`, signalling network access is expected.

### Caveats / weak spots specific to this package

1. **`native_toolchain_cmake` is the weakest link.** It is a **third-party
   package (publisher `rainyl.dev`, not `dart.dev`), still at `0.3.x`, and it
   self-labels "Experimental and may change without warning."** The hooks/code
   assets *platform* is stable, but this CMake helper is not, and can break
   across `0.x` bumps. Pin it tightly (`^0.3.0` currently) and expect churn.
   Dart's own `native_toolchain_c` is the stable/first-party alternative, but it
   compiles C sources directly rather than driving a CMake project, so it is not
   a drop-in replacement for open62541's CMake build.
2. **SDK floor.** Stable hooks require Dart 3.10. This branch **raises the
   constraint from `^3.9.0` to `^3.10.0`** so consumers on 3.9 (which predates
   stable hooks) are not offered an unusable version.
3. **Download over plain HTTP without a checksum.** `hook/build.dart` fetches the
   open62541 tarball from a `https://github.com/...` URL (good) but the code path
   and mbedTLS URL should be reviewed to ensure **HTTPS everywhere + a pinned
   version + a checksum verification**. The hook environment is semi-hermetic for
   reproducible/cacheable builds; an unpinned/unverified download is the main
   reproducibility and supply-chain weak spot. Not a publish blocker, but a
   recommended hardening.
4. **Build-time requirements are pushed onto every consumer.** Consumers need a
   C/C++ toolchain, **CMake**, and **network access** at build time, and the
   first build is slow. This is inherent to the download-and-build approach and
   should stay prominently documented (it is, in the README).
5. **Platform tags vs. reality.** pana derives platform tags from static import
   analysis and the `platforms:` block, not by running the hook. The `platforms:`
   block already declares linux/windows/macos/android/ios and pana shows 5/6.
   Confirm the tags render as intended on the live pub.dev page after publish,
   and confirm each declared platform actually builds (see checklist).

### Things that could NOT be verified here

- Whether pub.dev/pana **executes** the build hook during analysis. Docs describe
  static analysis only, which strongly implies the hook is *not* run at scoring
  time (so a download failure would not tank the score) — but this is inferred,
  not confirmed.
- An **actual native build on any platform** — no network build + CMake compile
  was run in this environment. Publishing should be gated on a green build on
  each target platform.
- **Dart 3.13 formatting.** Local Dart is 3.10.1; `dart format` is clean here,
  but the 3.13 formatter (used by CI/pub) was not run.

## 4. Changes made on the `pubdev-publish-prep` branch

- **`pubspec.yaml`**
  - Expanded `description` to a 50–180 char summary.
  - Added `homepage` and `issue_tracker`.
  - Raised SDK constraint `^3.9.0` → `^3.10.0` (stable build hooks).
  - (`repository`, `topics`, `platforms` were already present and valid.)
- **`CHANGELOG.md`** — new; documents the `1.5.6-1` entry and the version scheme.
- **`example/example.dart`** — new; minimal runnable client example (pana now
  detects an example).
- **`example/README.md`** — new; documents all four examples.
- **`README.md`** — rewritten from WIP developer notes into a user-facing README
  (features, platforms, the native-build explanation, install, usage), with the
  original build/regenerate notes preserved under a "Development" section.
- **`PUBLISHING.md`** — this file.

No source code under `lib/` was changed.

## 5. How to publish when ready — checklist

> The final `dart pub publish` is a **human action** requiring a pub.dev account
> with publish rights on the `open62541` package (or the `centroid.is`
> publisher). It was intentionally **not** run here.

1. **Decide the version.** `1.5.6-1` is a pre-release per semver (`-1` sorts
   *before* `1.5.6`). If you want it to be the "latest stable" on pub.dev, use a
   non-prerelease scheme (e.g. `1.5.6` then `1.5.7`, or `1.5.6+1` build metadata,
   or drop the suffix). Confirm the intended scheme before publishing, and keep
   `CHANGELOG.md` in sync.
2. **Bump native-build deps and re-test** (addresses the pana 10-point risk):
   - `dart pub upgrade --major-versions code_assets` (and align `hooks`).
   - Fix any `hook/build.dart` API breakage from the `1.x → 2.x` move.
   - Run a **real native build on every declared platform** (Linux, macOS,
     Windows, Android, iOS): `dart pub get` + `dart run example/example.dart …`
     and/or the CI matrix. Do **not** publish if any target fails to build.
3. **Harden the build hook** (recommended): HTTPS for all downloads, pinned
   versions, and checksum verification of the open62541 and mbedTLS archives.
4. **Verify tooling gates:** ensure `environment.sdk` (`^3.10.0`) matches the
   lowest SDK you actually build/test on; note in release text that consumers
   need Dart ≥ 3.10 / Flutter ≥ 3.38, CMake, a C/C++ toolchain, and network
   access at build time.
5. **Run formatting with the pub toolchain** (Dart 3.13):
   `dart format .` and commit any changes (could not be verified locally).
6. **Re-run the gates from a clean git state:**
   - `dart analyze --fatal-infos --fatal-warnings .` → no issues.
   - `dart pub publish --dry-run` → only the (now-absent) clean-state notice.
   - `pana --no-warning .` → confirm the score (160/160 today).
7. **Confirm ownership/verified publisher** on pub.dev, and that `LICENSE`,
   `README.md`, `CHANGELOG.md`, and `example/` are all present in the dry-run
   file list (they are).
8. **Publish (human):** `dart pub publish` and authenticate in the browser.
9. **Post-publish:** check the live pub.dev page — pub points, the platform tags,
   and that the README/example render correctly.
</content>
