# fbt on-prem

Build Android, Rust, Go, and .NET projects directly on this machine. No GitHub, no gists, no runner dispatch.

## Layout

```text
onprem/
  bin/fbt-local
  pipelines/android.sh
  pipelines/rust.sh
  pipelines/go.sh
  pipelines/dotnet.sh
  README.md
  NETWORKING.md
```

## Usage

```bash
onprem/bin/fbt-local build ./my-app
onprem/bin/fbt-local build ./my-app --release
onprem/bin/fbt-local build ./my-crate --rust --tests
onprem/bin/fbt-local build ./my-cmd --go
onprem/bin/fbt-local build ./my-cmd --go --goos windows --goarch amd64
onprem/bin/fbt-local build ./my-app --dotnet --runtime linux-x64
```

Output lands in `~/Downloads` by default, or the directory given by `--out` / `FBT_DOWNLOAD_DIR`.

Run `fbt-local --help` for the full flag list. Flags mirror `remote/bin/fbt` except there is no `--tool` and no gist transport.

## Toolchains

Required per pipeline, resolved at build time:

| Pipeline | Needs |
|---|---|
| Android | JDK (17 preferred), `gradle` or project `gradlew`, Android SDK, `apksigner` from build-tools for signed verification |
| Rust | `cargo`, `rustc`, `rustup` for `--target` installs, `cargo-ndk` for Android `--native` plus NDK under the SDK |
| Go | `go` toolchain |
| .NET | `dotnet` SDK 10 |

SDK lookup order: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Android/sdk`, `/usr/local/lib/android/sdk`, `/opt/android-sdk`. NDK lookup: `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`, then `$SDK/ndk/*`. JDK override: `JAVA_HOME_17`.

Missing toolchains fail with a plain message naming the binary. Nothing is auto-installed except `cargo-ndk` and Rust targets when `--native` / `--target` asks for them.

## Signing

Shared with the remote tool on purpose. `fbt-local keygen` writes the same files `remote/bin/fbt` uses:

```text
~/.config/fbt/release.p12
~/.config/fbt/signing.env
```

Overrides: `FBT_SIGNING_ENV`, `FBT_KEYSTORE`, `FBT_KEYSTORE_PASSWORD`, `FBT_KEY_ALIAS`, `FBT_KEY_PASSWORD`. A signed build stages credentials into a temp `GRADLE_USER_HOME` for that build only, verifies the APK cert with `apksigner`, then shreds the temp dir. The key never leaves this disk.

## Notes and limits

- Local-only. There is no listener, no port, no LAN exposure in this revision. See `NETWORKING.md` for the staged plan.
- One build at a time per invocation. Run serially.
- Same packaging exclusions as remote: `build/`, `.gradle/`, `.git/`, `.idea/`, `*.apk`, `*.aab`, `local.properties`. Uncommitted changes are included with a notice, same as before.
- Same artifact naming as remote: `<project>-<variant>.apk`, `<project>.tar.gz` or bare binaries for Rust, bare binary for Go, `<project>-<configuration>[-<runtime>].tar.gz` for .NET.
- No AAB output, same as remote.
- Go cross builds set `CGO_ENABLED=0`, same as remote.
