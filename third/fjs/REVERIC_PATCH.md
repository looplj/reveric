# Reveric FJS patch

Source baseline and archive checksum: `../fjs_UPSTREAM.md`.
Unmodified source import: source commit `59f330606`.
The following commit(s) touching this file and the listed paths are the patch
history; no parallel hand-maintained patch file is used.

## External module loading

`libfjs/src/api/runtime.rs` omits `FileResolver`, `NativeLoader` and
`ScriptLoader` from the shared resolver/loader stack. Unknown imports cannot
fall through to files or dynamic libraries. Host-registered memory modules
(including dynamic registrations) remain supported. No Dart/Rust public API or
FRB generated binding is changed.

This is capability restriction inside the application process, not OS or WASM
isolation. The host still owns APIs for file/bytecode inputs and optional builtin
modules: Codemode must use only in-memory source, `JsBuiltinOptions.none()`, and
no additional modules. Do not expose engine objects through its tool bridge.

Regression coverage creates a real JS file, tries relative, absolute, traversal
and dynamically assembled imports plus native-library names, and checks that a
host memory module still imports. Cancellation covers both occupied JS executor
workers, a microtask loop and a suspended Promise; upstream CPU and bridge-close
tests remain part of the gate.

## Optional builtins removed

Codemode creates engines with `JsBuiltinOptions.none()`, so none of the LLRT
builtin modules are reachable from scripts. They were still compiled in:
31 LLRT crates (including `child_process`, `fs`, `net`, `dgram`, `dns`, `http`,
`fetch` with TLS, `os`, `crypto`) plus `llrt_compression` and `flate2` (and, through
them, the brotli/zstd C libraries). This patch deletes them.

Kept, and why:

- `llrt_utils`: the module system uses `ModuleInfo`.
- `llrt_context`: `runtime/error_sink.rs` installs the spawn error handler.
- `llrt_timers`: the `engine_close_*` gate tests schedule background work with
  `setTimeout`. It registers `setTimeout`, `setInterval`, `setImmediate`, their
  clear functions and `queueMicrotask` only when `timers` is enabled; Codemode
  still passes `none()`. Cost: about 33 KB on macOS arm64.

Changes:

- `libfjs/Cargo.toml` / `Cargo.lock`: removed dependencies, including the
  `cfg(not(target_os = "ios"))` section that only held `llrt_os`.
- `libfjs/src/api/module.rs`: `JsBuiltinOptions::to_module_builder` registers
  only timers; new `unsupported_builtins()` lists enabled options this build lacks.
- `libfjs/src/api/runtime.rs`: `build_loaders` (the single entry for every
  runtime/engine) returns `JsError::runtime("Builtins not compiled into this
  build: ...")` when any unsupported option is enabled. Requesting a removed
  builtin fails fast instead of silently running without it. The presets
  `essential()`, `web()`, `node()` and `all()` therefore fail; use
  `JsBuiltinOptions { timers: Some(true), ..Default::default() }` for timers.
- Tests: deleted `llrt_module_tests.rs` and the builtin-specific
  `test_engine_with_*_builtin` tests in `engine_tests.rs`. Tests that used
  `essential()` only for timers use `tests::timers_only()`; module-listing tests
  use `timers` instead of `path`/`https`/`dgram`; `test_async_runtime_with_builtin_all`
  now asserts the fail-fast error. Tests that only read preset flags are unchanged.

`JsBuiltinOptions` fields, presets and the Dart/FRB API are intentionally
unchanged, so no bridge code is regenerated.

Measured release `libfjs` sizes before -> after (same toolchain and profile):

| Target | Raw | gzip -9 |
| --- | --- | --- |
| aarch64-apple-darwin dylib | 7.42 MB -> 1.99 MB | 4.09 MB -> 1.03 MB |
| aarch64-linux-android so | 8.63 MB -> 2.35 MB (measured without timers) | 4.44 MB -> 1.13 MB |

### Merging upstream fixes

We do not track upstream wholesale; upstream fixes are brought in commit by
commit when needed.

1. Cherry-pick or hand-apply the upstream commit. Conflicts in the areas above
   are expected: keep our version of the dependency list and of
   `to_module_builder`, keep the `build_loaders` check, and drop upstream
   changes that only touch removed builtins or their tests.
2. If the upstream commit bumps the LLRT `rev`, update only the kept crates
   (`llrt_utils`, `llrt_context`, `llrt_timers`) and keep the same `rev` for all
   three and for the `rquickjs` patch.
3. If upstream adds a builtin option field, add it to `unsupported_builtins()`
   unless we deliberately compile it in; otherwise enabling it is silently ignored.
4. Run the full `cargo test --locked` for `libfjs`, the gate commands below,
   rebuild the archive and run `codemode_native_test` on the app target.

### Re-enabling a builtin

Add its crate back to `Cargo.toml` with the same LLRT `rev`, restore its branch
in `to_module_builder` from upstream `module.rs`, remove it from
`unsupported_builtins()`, and restore its upstream tests. Codemode must keep
using `JsBuiltinOptions.none()`; any builtin exposed to Codemode scripts needs its
own capability review first.

## Build identity and dependencies

Reveric pins FJS 3.3.1 and flutter_rust_bridge 2.12.0, with a local path override.
Root `cargokit_options.yaml` disables upstream binary download. Apple archives
are ignored build artifacts and must be generated from this source. The local
CargoKit recipe retains Rust 1.99.1 and labels Flutter 3.49.0-0.1.pre and Apple
Xcode/SDK 26.2 instead of upstream's older labels. The Flutter label is
informational: Flutter only hosts the build tool and dart-sys ships its own
Dart API headers, so upgrading Flutter does not require rebuilding the archive.

Build with any Flutter SDK as `FLUTTER_ROOT` for the upstream script (the project
FVM SDK when present), then run native integration tests against the app target:

```sh
cargo +1.99.1 test --locked --manifest-path third/fjs/libfjs/Cargo.toml codemode_ -- --test-threads=1
cargo +1.99.1 test --locked --manifest-path third/fjs/libfjs/Cargo.toml engine_close_ -- --test-threads=1
sh third/fjs/tool/build_fjs_xcframework.sh
timeout 900 fvm flutter test integration_test/codemode_native_test.dart -d macos
```

The integration test uses the application's default FJS library loader, never a
mock bridge or manually opened Rust test library. Verify the packaged framework
against the rebuilt archive; source test success alone is not evidence that an
app loaded patched code. Repeat on every supported native platform before
release; an iOS build alone does not replace a device run.

Remove the loader patch only when an upgraded upstream enforces the same
restriction and these behavior tests pass. Keep this restriction separate from
the optional builtin removal below. Never substitute an upstream prebuilt archive
when compilation fails.

## Reproducible local platform builds

The ordinary CargoKit RustBuilder also reads the existing build_recipe Rust
pin when no explicit build override is present; Windows, Android and Linux no
longer silently select the host stable toolchain. Cargo builds use --locked.
The focused builder regression checks the emitted compiler and Cargo toolchain.

`third/fjs/tool/build_runtime.sh` uses the root FVM SDK (or the active Flutter)
and builds/verifies the Apple archive before Makefile/CI app builds, reusing a
machine-level cache keyed by the identity below. `third/fjs/tool/artifact.py` records
source hashes (including patch, Cargo.lock, version and builder),
Rust/compiler identity, host architecture, three Apple arm64 targets (macOS; iOS device and simulator) and Xcode/SDKs.
A cache entry is accepted only when identity and SHA-256 match. Its local CargoKit
generation manifest must identify Rust 1.99.1 and the same archive checksum.
`--verify-app APP` compares packaged macOS framework UUIDs with that archive;
actual native boundary tests remain required separately.

The generated zip, checksum and provenance record stay under ignored Binaries/.
No upstream archive fallback, public FJS API change or platform permission change.

## Native plugin UI

`libfjs/src/ui/reactive.rs` and `ui/reactive/tests.rs` are extracted from
nsh commit `201d780a9339b886ac87c741d3d4fd8fb64e1d30`, paths
`crates/nsh-core/src/reactive.rs` and `crates/nsh-core/src/reactive/tests.rs`.
The upstream workspace declares Apache-2.0; its standard license text is
preserved in `ui/LICENSE.nsh`. The graph algorithm and tests are retained.
The UI adapter uses the existing pinned rquickjs engine, without linking nsh's
QuickJS fork or its platform/layout crates.

The extracted graph adds a read-only reference visitor for precise QuickJS GC
marking and an opt-in lazy-memo flag. Imported memos retain their original eager
behavior; plugin `computed` nodes skip eager update queuing and are brought up
to date by reads (including downstream effect reads). The native binding tests
cover lazy caching in addition to the unmodified upstream graph cases.

`ui/harden.js` is adapted from the `HARDEN` script in nsh commit
`d5225a854084ed5e1a3b66c47aa30388b975f4e9`, `crates/nsh-js/src/sandbox.rs`
(same license). `ui/session.rs` runs it after the host scripts and before the
plugin view: `eval` is deleted, the function constructors throw, and the shared
built-in prototypes (except `Error.prototype`) are frozen with the upstream
override-mistake accessors. Host evaluation from Rust is unaffected. The view
script is evaluated as `plugin-view.js` so the host can map its stack frames
through the view source map.

Reveric-specific UI adapter behavior, all covered by `ui::` tests (run with
`--test-threads=1`; the API tests count global engines):

- `ui/schema.rs` (generated by `plugins/sdk/generate_ui.mjs`) types every
  property per component; `bindings.rs` rejects unknown or mistyped props as
  `Unknown {Component} property {key}` / `Invalid {Component}.{key}: expected ...`.
- `ui/nodes.rs` `Tree::reorder` moves only rows outside the longest stable
  subsequence when a keyed `Each` reorders.
- `ui/sdk.js` skips props equal to the last sent value, keeps one native
  listener per event and swaps handlers behind it, and adds `ErrorBoundary`,
  which also contains failures from effects, listeners and timers created
  inside it.
- Dispatch records `editRevision` from both `onChange` and `onSubmit`, so a
  value written back by either handler is not treated as stale by the host.

## Continuous task execution budget

`JsEngine.setExecutionTimeLimit` is opt-in and disabled by default. The existing
async driver's monotonic budget spans runnable JavaScript and microtasks, resets
when the runtime has no runnable jobs, and is checked by the same native
interrupt handler as shutdown. Host Promise waiting does not consume the
budget; an outstanding but unawaited Host call cannot exempt a CPU loop.
Foreground polls notify the driver when they yield so idle detection also
covers long Host operations. Existing engine close error diagnostics remain
intact. Native tests cover CPU/microtask interruption, awaited Host latency,
fire-and-forget calls and normal close regressions.

## Resident plugin contexts

`JsEngineGroup` owns one restricted QuickJS runtime and driver. `createEngine()`
creates a separate context with its own globals, intrinsics, module registry,
bridge callback and cancellation state. Ordinary `JsEngine.create()` remains an
independent runtime for Codemode; native TSX sessions retain their existing path.

rquickjs stores `Ctx::userdata` on the runtime, not the context. FJS therefore
keys module metadata, cached conversion intrinsics and error sinks by native
context identity in `runtime/context_data.rs`, and removes those entries during
context teardown. Child engines consume only their own background errors, and
the queue cap applies per context so one realm cannot evict a sibling's errors.
Because a child context outlives individual calls, its queued background errors
do not fail the next engine operation; the host drains them explicitly, and
`close()` still reports whatever remains after teardown.
Bridge identity comes from the native callback attached to that context;
application invocation tokens cannot select a sibling context's callback.

Closing a child revokes even saved copies of its native bridge and cancels its
pending host waits without shutting down the shared driver. Closing the group,
or hitting its continuous execution budget, cancels all children. The memory
limit is also shared. The application rebuilds the group after fatal resource
errors and reloads registrations lazily; it does not replay failed writes.

Regression tests prove shared runtime ownership, global/prototype and module
isolation, context-local value conversion and background diagnostics, native
bridge revocation, sibling survival after context close, and group-wide native
interrupts. Application tests also exercise stringify-based token theft,
explicitly supplied foreign tokens, global slot enumeration and pollution
cleanup on plugin unload/update.
