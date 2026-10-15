#!/usr/bin/env bash
set -euo pipefail
die() { printf 'fbt-local dotnet: %s\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1" >&2; }
srcdir=""
distdir=""
configuration="Release"
runtime=""
run_tests="false"
project="app"
while [ $# -gt 0 ]; do
  case "$1" in
    --configuration) configuration="${2:-}"; shift 2 ;;
    --runtime) runtime="${2:-}"; shift 2 ;;
    --tests) run_tests="true"; shift ;;
    --project) project="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -h|--help) printf 'usage: dotnet.sh <srcdir> <distdir> [options]\n' >&2; exit 0 ;;
    *) if [ -z "$srcdir" ]; then srcdir="$1"; shift; elif [ -z "$distdir" ]; then distdir="$1"; shift; else die "unknown argument: $1"; fi ;;
  esac
done
[ -n "$srcdir" ] || die "missing <srcdir>"
[ -n "$distdir" ] || die "missing <distdir>"
[ -d "$srcdir" ] || die "not a directory: $srcdir"
case "$configuration" in
  Release|Debug) ;;
  *) die "configuration must be Release or Debug, got '$configuration'" ;;
esac
if [ -n "$runtime" ]; then
  printf '%s' "$runtime" | grep -Eq '^[a-z]+-[a-z0-9]+$' || die "invalid runtime identifier: '$runtime'"
fi
command -v dotnet >/dev/null 2>&1 || die "dotnet SDK is not installed"
target=""
for f in "$srcdir"/*.sln; do
  [ -e "$f" ] && { target="$(basename "$f")"; root="$srcdir"; break; }
done
if [ -z "$target" ]; then
  for f in "$srcdir"/*.csproj; do
    [ -e "$f" ] && { target="$(basename "$f")"; root="$srcdir"; break; }
  done
fi
if [ -z "$target" ]; then
  found="$(find "$srcdir" -maxdepth 2 \( -name '*.sln' -o -name '*.csproj' \) -type f 2>/dev/null | sort | head -1)"
  [ -n "$found" ] || die "no .sln or .csproj found under $srcdir"
  target="$(basename "$found")"
  root="$(dirname "$found")"
fi
info "target: $target"
if [ "$run_tests" = "true" ]; then
  (cd "$root" && dotnet test "$target" -c "$configuration")
fi
mkdir -p "$distdir/pub"
args=(-c "$configuration" -o "$distdir/pub")
[ -n "$runtime" ] && args+=(-r "$runtime")
(cd "$root" && dotnet publish "$target" "${args[@]}")
[ -n "$(ls -A "$distdir/pub")" ] || die "publish produced no output"
tarball="$project-$configuration"
[ -n "$runtime" ] && tarball="$tarball-$runtime"
tarball="$tarball.tar.gz"
tar czf "$distdir/$tarball" -C "$distdir/pub" .
rm -rf "$distdir/pub"
ls -l "$distdir"
