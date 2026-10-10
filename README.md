# fbt

Build Android and Rust projects on GitHub-hosted runners, without installing a
local JDK, Android SDK, or Rust toolchain.

Source is packaged into a secret gist, built on a runner, and the output lands
in a local downloads directory. The gist is deleted after every run, whether
the build succeeds or fails, so nothing accumulates.

Because the build job runs in a **public** repository, runner minutes are free
and unlimited. Source is never committed to that repository and never appears
in its public event archive.

## Supported pipelines

| Pipeline | Workflow | Output |
|---|---|---|
| Android | `android.yml` | `.apk` |
| Rust | `rust.yml` | tarball, `.rlib`, or native library, depending on crate type |

### Android

Uses JDK 17 and Gradle 9.6.0, matching AGP 9.4.x requirements. Prefers
`./gradlew` when the project has a Gradle wrapper and falls back to a
`gradle` binary otherwise, so projects without a committed wrapper still build.
Packaging is always an `.apk` named `<project>-<variant>.apk`.

Release builds are signed with a single release key shared by every project.
See [Release signing](#release-signing).

### Rust

Uses the stable toolchain via `dtolnay/rust-toolchain`, with an `actions/cache`
entry covering the cargo registry and `target/` directory. The crate root is
found at the archive root or one level down, so both a single crate and a
directory of crates work.

Artifact collection inspects what the build actually produced:

| Crate shape | Detected as | Output |
|---|---|---|
| has `[[bin]]` | `bin` | `<project>.tar.gz` with binaries, license and readme; `--raw` gives bare `.bin` files |
| `crate-type = ["cdylib", ...]` | `native` | `.so` / `.dylib` / `.dll` / `.a` |
| plain `[lib]` | `lib` | `.rlib` |

Libraries are filtered to the crate's own artifacts by matching the crate name
from `Cargo.toml`, so a build does not return every transitive dependency.

## Usage

```bash
fbt build <project-dir> [options]
```

Android:

```bash
fbt build ./my-app                     # debug variant (default)
fbt build ./my-app --release           # signed release variant
fbt build ./my-app --variant release   # release variant, unsigned
```

`--release` is shorthand for `--variant release --sign`. `--sign` applies to
whatever variant was selected, and `--no-sign` cancels both, so
`fbt build ./my-app --release --no-sign` gives an unsigned release.

Rust:

```bash
fbt build ./my-crate --rust                       # release build (default)
fbt build ./my-crate --rust --profile dev
fbt build ./my-crate --rust --tests               # cargo test, then build
fbt build ./my-crate --rust --target aarch64-unknown-linux-gnu
fbt build ./my-crate --rust --features foo,bar
fbt build ./my-crate --rust --all-features
fbt build ./my-crate --rust --no-default-features
fbt build ./my-crate --rust --raw                 # bare binaries instead of tarball
```

Run `fbt build --help` for the full flag list.

## Release signing

One key signs every release build, so there is a single thing to back up and a
single thing to rotate.

Setup is two steps and happens once:

```bash
fbt keygen        # create ~/.config/fbt/release.p12 and record it in signing.env
fbt key push      # store it as an Actions secret on the tool repo
```

`fbt keygen` generates the key locally and reads passwords from the terminal,
never from a command-line argument. It uses `keytool` when a JDK is present and
falls back to `openssl`, producing a PKCS#12 keystore either way, so the key can
be created on a machine that has only one of the two. `fbt key` reports the local
key's SHA-256 fingerprint and which signing secrets the tool repo currently
holds.

The key is then stored as four repository secrets, `gh secret set` never taking
the value as an argument:

| Secret | Contents |
|---|---|
| `RELEASE_KEYSTORE_B64` | base64 of the keystore file |
| `RELEASE_KEYSTORE_PASSWORD` | keystore password |
| `RELEASE_KEY_ALIAS` | key alias |
| `RELEASE_KEY_PASSWORD` | key password |

These names match the convention a project's own CI conventionally uses, so one
key can serve both a project-side release workflow and `fbt`.

A signed build sends only `signed=true` in the dispatch payload. On the runner
the keystore is decoded into the runner's temp directory and its certificate is
read back with `keytool`, giving the expected SHA-256 fingerprint. The build
receives the credentials as Gradle properties rather than command-line flags,
under both the `android.injected.signing.*` names AGP honours regardless of the
project's build file, and the `RELEASE_*` names a project's own `signingConfigs`
block conventionally reads. An explicit `signingConfigs` entry wins over the
injected properties, so a project that already declares one keeps using it.

After the build, `apksigner` verifies the APK and its signer certificate is
compared against the keystore's. A signed build **fails** if the APK is unsigned
or was signed with a different key. This matters because AGP silently falls back
to the debug key for a project with no release `signingConfigs` block, which
otherwise produces a perfectly plausible-looking debug-signed "release". The
keystore and the properties block are shredded afterwards, including on failure.

### What this does not protect against

- **The key is only as safe as the tool repository.** The secrets live on a
  public repository. They are not readable through the API and are masked in
  logs, but every workflow that runs there can use them. Keep the number of
  workflows that touch them small.
- **Keep an offline backup.** Repository secrets are not a backup. If the key is
  lost, apps signed with it can never be updated, only uninstalled and
  reinstalled under a new application id. `fbt key push` refuses to overwrite an
  existing keystore secret without a typed confirmation for the same reason.
- **A signed build runs third-party code with the key present.** Gradle executes
  plugins and dependencies downloaded during the build while the keystore is on
  the runner. Build only from checkouts you trust.
- **Fork pull requests are not a vector.** Builds are dispatched only by
  `repository_dispatch`, which needs authentication, so opening a pull request
  cannot trigger a job that can read these secrets.

## Configuration

`fbt` needs to know which repository holds the workflows. Set it once in
`~/.config/fbt/config`:

```bash
TOOL_REPO=<owner>/<repo>
DOWNLOAD_DIR=<path>          # optional, defaults to ~/Downloads
```

Or pass `--tool <owner>/<repo>` per invocation, or set `FBT_TOOL_REPO` in the
environment.

Signing material lives beside the config file. Point `FBT_SIGNING_ENV` or
`FBT_KEYSTORE_PATH` elsewhere to keep a key outside `~/.config`, and override
individual values with `FBT_KEYSTORE`, `FBT_KEYSTORE_PASSWORD`, `FBT_KEY_ALIAS`
and `FBT_KEY_PASSWORD`, which take precedence over the file.

### Repository setup

Clone this repository and add a gist token as an Actions secret:

```bash
gh secret set GIST_TOKEN --repo <owner>/<repo>
```

The token needs the **Gists** account permission set to **write**, and nothing
else. On the fine-grained token page it appears under *Account permissions*
rather than repository permissions, so the resource owner must be the user
account. Gist access is not affected by repository scoping.

Release signing adds four more secrets. `fbt key push` sets all of them; see
[Release signing](#release-signing).

## How a build works

1. `fbt` packages the project. For a git repository it uses
   `git archive --format=tar.gz HEAD`, which honours `.gitignore` and keeps
   `build/`, `.gradle/`, and `*.apk` out of the archive. Non-git directories
   fall back to `tar` with the same exclusions. Uncommitted changes are
   reported but not included.
2. The tarball is base64-encoded and uploaded as a secret gist. Gists only
   accept text, so base64 is the transport encoding; the runner decodes it. The
   signing key never travels this way; it stays in the runner's secret store.
3. A `repository_dispatch` event fires the matching workflow.
4. The runner fetches the gist, extracts it, builds, verifies the signature if
   one was asked for, and uploads the output as a workflow artifact.
5. `fbt` downloads the artifact into the downloads directory.
6. The gist is deleted by an `if: always()` step in the workflow and again by
   `fbt` after a successful download. A failed or cancelled build cannot leave
   source behind.

## Notes and limits

- **Gist size limits.** Gists are a transport, not a build input format. Source
  with large binary assets can exceed what a gist accepts. A Cloudflare R2
  bucket with presigned URLs is the intended upgrade path.
- **Base64 overhead.** Encoded source is roughly 33% larger than the tarball.
- **Android signing is opt-in.** Without `fbt key push`, a `--variant release`
  build is unsigned or debug-signed exactly as before. See
  [Release signing](#release-signing) for what a signed build does and does not
  protect against.
- **No AAB.** The Android pipeline always produces an `.apk`. Play Store uploads
  need a bundle, which is not currently supported.
- **Host Rust targets only.** Cross-compiling to `*-linux-android` targets
  needs the NDK and a configured linker. `--target` passes the triple through,
  but only host builds are exercised.
- **No `pull_request` or `pull_request_target` triggers.** Anyone can open a
  pull request on a public repository, and those triggers run with repository
  secrets and a write-scoped token. Builds are dispatched only by
  `repository_dispatch`, which requires authentication.
- **Input validation.** Target triples and feature lists are validated against
  an allowlist before reaching a shell, so a crafted dispatch cannot inject
  commands.