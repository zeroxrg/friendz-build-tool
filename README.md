# friendz-build-tool

Two variants, one repo.

- `github/` — the original GitHub-pipeline tool. Source is packaged into a secret gist, built on a hosted runner, output downloaded as a workflow artifact, gist deleted afterwards. See `github/README.md`. Archived in place; re-enable by moving `github/.github` back to the repo root so Actions picks the workflows up again.
- `onprem/` — the local variant. Builds run directly on this machine via `onprem/bin/fbt-local`, no GitHub, no gist, no runner. See `onprem/README.md`.

Both share the flag surface (`--release`, `--rust`, `--go`, `--dotnet`, `--tests`, `--native`, `--abis`) and the signing material in `~/.config/fbt/`, so one release key serves both.
