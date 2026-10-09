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
fbt build ./my-app --variant release
```

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

## Configuration

`fbt` needs to know which repository holds the workflows. Set it once in
`~/.config/fbt/config`:

```bash
TOOL_REPO=<owner>/<repo>
DOWNLOAD_DIR=<path>          # optional, defaults to ~/Downloads
```

Or pass `--tool <owner>/<repo>` per invocation, or set `FBT_TOOL_REPO` in the
environment.

### Repository setup

Clone this repository and add a gist token as an Actions secret:

```bash
gh secret set GIST_TOKEN --repo <owner>/<repo>
```

The token needs the **Gists** account permission set to **write**, and nothing
else. On the fine-grained token page it appears under *Account permissions*
rather than repository permissions, so the resource owner must be the user
account. Gist access is not affected by repository scoping.

## How a build works

1. `fbt` packages the project. For a git repository it uses
   `git archive --format=tar.gz HEAD`, which honours `.gitignore` and keeps
   `build/`, `.gradle/`, and `*.apk` out of the archive. Non-git directories
   fall back to `tar` with the same exclusions. Uncommitted changes are
   reported but not included.
2. The tarball is base64-encoded and uploaded as a secret gist. Gists only
   accept text, so base64 is the transport encoding; the runner decodes it.
3. A `repository_dispatch` event fires the matching workflow.
4. The runner fetches the gist, extracts it, builds, and uploads the output as
   a workflow artifact.
5. `fbt` downloads the artifact into the downloads directory.
6. The gist is deleted by an `if: always()` step in the workflow and again by
   `fbt` after a successful download. A failed or cancelled build cannot leave
   source behind.

## Notes and limits

- **Gist size limits.** Gists are a transport, not a build input format. Source
  with large binary assets can exceed what a gist accepts. A Cloudflare R2
  bucket with presigned URLs is the intended upgrade path.
- **Base64 overhead.** Encoded source is roughly 33% larger than the tarball.
- **Debug Android builds only.** No keystore is involved, so no signing secrets
  live in this repository. Adding signed releases changes the security model.
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