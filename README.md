# fbt

Build Android projects through GitHub Actions, without installing a JDK or
Android Studio locally.

Source is packaged into a secret gist, built on a GitHub-hosted runner, and the
APK lands in `~/Downloads`. The gist is deleted after every run, successful or
not, so nothing accumulates.

Because the build runs in this **public** repo, the runner minutes are free.
Your source is never committed here and never appears in the public event
archive.

## Requirements

- `gh` authenticated (`gh auth status`)
- `bash`, `tar`, `git`
- A `GIST_TOKEN` secret on this repository (see Setup)

## Usage

```bash
fbt build ~/Friendz
fbt build ~/some/project --variant debug
```

Output goes to `~/Downloads/<project>-<variant>.apk`.

## Setup

The build workflow needs a token that can read the source gist. Add it as an
Actions secret on this repository:

```bash
gh secret set GIST_TOKEN --repo zeroxrg/friendz-build-tool
```

The token needs gist scope and nothing else. It does not need access to any
repository, which keeps the blast radius small if it ever leaks.

## Config

Optional, at `~/.config/fbt/config`:

```bash
TOOL_REPO=zeroxrg/friendz-build-tool
DOWNLOAD_DIR=/home/raymond/Downloads
```

## How a build works

1. `fbt` archives the project. For a git repo it uses `git archive` on `HEAD`
   plus a note about uncommitted changes, so `build/`, `.gradle/` and
   `*.apk` never enter the tarball.
2. The tarball is uploaded as a secret gist.
3. A `repository_dispatch` event fires this repo's `android.yml`.
4. The runner fetches the gist, extracts it, and runs the Gradle build.
5. The APK is uploaded as a workflow artifact.
6. The gist is deleted by an `if: always()` step, so a failed build cannot
   leave source behind.

## Notes

- **No Gradle wrapper required.** The workflow prefers `./gradlew` when present
  and otherwise falls back to the Gradle installed by
  `gradle/actions/setup-gradle`. Projects without a wrapper work.
- **Gradle 9.6.0, JDK 17.** Chosen for AGP 9.4.x compatibility. A project
  pinned to an older AGP may need different versions.
- **Gist size limits.** Gists are a transport, not a build input format. A
  project with large binary assets will exceed what a gist accepts. The
  intended upgrade path is Cloudflare R2 with presigned URLs.
- **Debug builds only.** No keystore is involved, so no signing secrets live
  in this repo.