#!/usr/bin/env bash
set -euo pipefail
die() { printf 'fbt-local rust: %s\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1" >&2; }
srcdir=""
distdir=""
profile="release"
target=""
features=""
all_features="false"
no_default_features="false"
run_tests="false"
raw="false"
project="crate"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --features) features="${2:-}"; shift 2 ;;
    --all-features) all_features="true"; shift ;;
    --no-default-features) no_default_features="true"; shift ;;
    --tests) run_tests="true"; shift ;;
    --raw) raw="true"; shift ;;
    --project) project="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -h|--help) printf 'usage: rust.sh <srcdir> <distdir> [options]\n' >&2; exit 0 ;;
    *) if [ -z "$srcdir" ]; then srcdir="$1"; shift; elif [ -z "$distdir" ]; then distdir="$1"; shift; else die "unknown argument: $1"; fi ;;
  esac
done
[ -n "$srcdir" ] || die "missing <srcdir>"
[ -n "$distdir" ] || die "missing <distdir>"
[ -d "$srcdir" ] || die "not a directory: $srcdir"
case "$profile" in
  release|dev) ;;
  *) die "profile must be release or dev, got '$profile'" ;;
esac
if [ -n "$target" ]; then
  printf '%s' "$target" | grep -Eq '^[a-z0-9_]+(-[a-z0-9_]+)*$' || die "invalid target triple: '$target'"
fi
if [ -n "$features" ]; then
  printf '%s' "$features" | grep -Eq '^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$' || die "invalid features list: '$features'"
fi
command -v cargo >/dev/null 2>&1 || die "cargo is not installed"
command -v rustc >/dev/null 2>&1 || die "rustc is not installed"
if [ -f "$srcdir/Cargo.toml" ]; then
  root="$srcdir"
else
  root="$(find "$srcdir" -maxdepth 2 -name Cargo.toml -type f -printf '%h\n' 2>/dev/null | head -1)"
  [ -n "$root" ] || die "no Cargo.toml found under $srcdir"
fi
info "crate root: $root"
if [ "$run_tests" = "true" ]; then
  args=(--all-targets)
  [ -n "$features" ] && args+=(--features "$features")
  [ "$all_features" = "true" ] && args+=(--all-features)
  [ "$no_default_features" = "true" ] && args+=(--no-default-features)
  (cd "$root" && cargo test "${args[@]}")
fi
if [ -n "$target" ]; then
  if ! rustc --print target-list 2>/dev/null | grep -qxF "$target"; then
    info "installing target $target"
    rustup target add "$target" || die "could not install target $target"
  fi
fi
build_args=()
[ "$profile" = "release" ] && build_args+=(--release)
[ -n "$target" ] && build_args+=(--target "$target")
[ -n "$features" ] && build_args+=(--features "$features")
[ "$all_features" = "true" ] && build_args+=(--all-features)
[ "$no_default_features" = "true" ] && build_args+=(--no-default-features)
(cd "$root" && cargo build "${build_args[@]}")
host="$(rustc -vV | sed -n 's/^host: //p')"
triple="${target:-$host}"
if [ "$profile" = "release" ]; then subdir="release"; else subdir="debug"; fi
mkdir -p "$distdir"
candidates=("target/${triple}/${subdir}" "target/${subdir}" "target/${triple}" "target")
kind=""
found=()
for cand in "${candidates[@]}"; do
  full="$root/$cand"
  [ -d "$full" ] || continue
  while IFS= read -r -d '' f; do found+=("$f"); done \
    < <(find "$full" -maxdepth 1 -type f -executable ! -name '*.d' -print0 2>/dev/null)
  if [ "${#found[@]}" -gt 0 ]; then kind="bin"; break; fi
done
if [ "${#found[@]}" -eq 0 ]; then
  kind="native"
  for cand in "${candidates[@]}"; do
    full="$root/$cand"
    [ -d "$full" ] || continue
    while IFS= read -r -d '' f; do found+=("$f"); done \
      < <(find "$full" -maxdepth 1 -type f \( -name '*.so' -o -name '*.dylib' -o -name '*.dll' -o -name '*.a' \) ! -name '*.d' -print0 2>/dev/null)
    if [ "${#found[@]}" -gt 0 ]; then break; fi
  done
fi
if [ "${#found[@]}" -eq 0 ]; then
  kind="lib"
  for cand in "${candidates[@]}"; do
    full="$root/$cand"
    [ -d "$full" ] || continue
    while IFS= read -r -d '' f; do found+=("$f"); done \
      < <(find "$full" -maxdepth 1 -type f -name '*.rlib' -print0 2>/dev/null)
    if [ "${#found[@]}" -gt 0 ]; then break; fi
  done
fi
crate_name="$(sed -n 's/^name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$root/Cargo.toml" | head -1)"
if [ -n "$crate_name" ] && [ "$kind" != "bin" ] && [ "${#found[@]}" -gt 0 ]; then
  filtered=()
  for b in "${found[@]}"; do
    case "$(basename "$b")" in
      *"$crate_name"*) filtered+=("$b") ;;
    esac
  done
  [ "${#filtered[@]}" -gt 0 ] && found=("${filtered[@]}")
fi
[ "${#found[@]}" -gt 0 ] || die "build produced no recognisable artifacts"
info "found ${#found[@]} $kind artifact(s)"
if [ "$raw" = "true" ] || [ "$kind" = "lib" ] || [ "$kind" = "native" ]; then
  for b in "${found[@]}"; do
    cp "$b" "$distdir/$(basename "$b")"
  done
  ls "$distdir"
else
  mkdir -p "$distdir/pkg"
  for b in "${found[@]}"; do
    cp "$b" "$distdir/pkg/$(basename "$b")"
  done
  for extra in README.md README LICENSE LICENSE-MIT LICENSE-APACHE COPYING; do
    if [ -f "$root/$extra" ]; then cp "$root/$extra" "$distdir/pkg/"; fi
  done
  tar czf "$distdir/${project}.tar.gz" -C "$distdir" pkg
  rm -rf "$distdir/pkg"
  ls "$distdir"
fi
