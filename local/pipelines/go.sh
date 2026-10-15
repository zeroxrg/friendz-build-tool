#!/usr/bin/env bash
set -euo pipefail
die() { printf 'fbt-local go: %s\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1" >&2; }
srcdir=""
distdir=""
goos=""
goarch=""
run_tests="false"
project="app"
while [ $# -gt 0 ]; do
  case "$1" in
    --goos) goos="${2:-}"; shift 2 ;;
    --goarch) goarch="${2:-}"; shift 2 ;;
    --tests) run_tests="true"; shift ;;
    --project) project="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -h|--help) printf 'usage: go.sh <srcdir> <distdir> [options]\n' >&2; exit 0 ;;
    *) if [ -z "$srcdir" ]; then srcdir="$1"; shift; elif [ -z "$distdir" ]; then distdir="$1"; shift; else die "unknown argument: $1"; fi ;;
  esac
done
[ -n "$srcdir" ] || die "missing <srcdir>"
[ -n "$distdir" ] || die "missing <distdir>"
[ -d "$srcdir" ] || die "not a directory: $srcdir"
if [ -n "$goos" ]; then
  printf '%s' "$goos" | grep -Eq '^[a-z0-9]+$' || die "invalid goos: '$goos'"
fi
if [ -n "$goarch" ]; then
  printf '%s' "$goarch" | grep -Eq '^[a-z0-9]+$' || die "invalid goarch: '$goarch'"
fi
command -v go >/dev/null 2>&1 || die "go is not installed"
if [ -f "$srcdir/go.mod" ]; then
  root="$srcdir"
else
  root="$(find "$srcdir" -maxdepth 2 -name go.mod -type f -printf '%h\n' 2>/dev/null | head -1)"
  [ -n "$root" ] || die "no go.mod found under $srcdir"
fi
info "module root: $root"
if [ "$run_tests" = "true" ]; then
  (cd "$root" && go test ./...)
fi
mkdir -p "$distdir"
mod="$(awk '$1 == "module" { print $2; exit }' "$root/go.mod")"
name="${mod##*/}"
[ -n "$name" ] || name="$project"
if [ -n "$goos" ]; then export GOOS="$goos"; fi
if [ -n "$goarch" ]; then export GOARCH="$goarch"; fi
export CGO_ENABLED=0
(cd "$root" && go build -o "$distdir/$name" .)
[ -x "$distdir/$name" ] || die "$root has no main package: nothing executable to upload"
ls -l "$distdir"
