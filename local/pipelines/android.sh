#!/usr/bin/env bash
set -euo pipefail
die() { printf 'fbt-local android: %s\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1" >&2; }
srcdir=""
distdir=""
variant="debug"
signed="false"
native=""
abis="arm64-v8a"
project="App"
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) variant="${2:-}"; shift 2 ;;
    --sign) signed="true"; shift ;;
    --no-sign) signed="false"; shift ;;
    --native) native="${2:-}"; shift 2 ;;
    --abis) abis="${2:-}"; shift 2 ;;
    --project) project="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -h|--help) printf 'usage: android.sh <srcdir> <distdir> [options]\n' >&2; exit 0 ;;
    *) if [ -z "$srcdir" ]; then srcdir="$1"; shift; elif [ -z "$distdir" ]; then distdir="$1"; shift; else die "unknown argument: $1"; fi ;;
  esac
done
[ -n "$srcdir" ] || die "missing <srcdir>"
[ -n "$distdir" ] || die "missing <distdir>"
[ -d "$srcdir" ] || die "not a directory: $srcdir"
printf '%s' "$variant" | grep -Eq '^[A-Za-z][A-Za-z0-9]*$' || die "invalid variant: '$variant'"
case "$signed" in true|false) ;; *) die "signed must be true or false" ;; esac
if [ -n "$native" ]; then
  case "$native" in /*|*..*) die "invalid native crate dir: '$native'" ;; esac
  printf '%s' "$native" | grep -Eq '^[A-Za-z0-9_./-]+$' || die "invalid native crate dir: '$native'"
  [ -f "$srcdir/$native/Cargo.toml" ] || die "no Cargo.toml under '$native'"
fi
printf '%s' "$abis" | grep -Eq '^[A-Za-z0-9_,-]+$' || die "invalid abis: '$abis'"
for _abi in $(printf '%s' "$abis" | tr ',' ' '); do
  case "$_abi" in arm64-v8a|armeabi-v7a|x86_64|x86) ;; *) die "unsupported ABI '$_abi'" ;; esac
done
command -v java >/dev/null 2>&1 || die "java is not installed"
if [ -x "$srcdir/gradlew" ]; then gradle_cmd="$srcdir/gradlew"; elif command -v gradle >/dev/null 2>&1; then gradle_cmd="gradle"; else die "no gradlew wrapper and no gradle binary found"; fi
if [ -n "${JAVA_HOME_17:-}" ] && [ -x "$JAVA_HOME_17/bin/java" ]; then
  export JAVA_HOME="$JAVA_HOME_17"
else
  j17="$(ls -d /usr/lib/jvm/*17* 2>/dev/null | head -1)"
  if [ -n "$j17" ] && [ -x "$j17/bin/java" ]; then
    export JAVA_HOME="$j17"
  fi
fi
sdk=""
for cand in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/sdk" /usr/local/lib/android/sdk /opt/android-sdk; do
  if [ -n "$cand" ] && [ -d "$cand/platform-tools" ]; then sdk="$cand"; break; fi
done
[ -n "$sdk" ] || die "no Android SDK found (tried ANDROID_HOME, ~/Android/sdk)"
export ANDROID_HOME="$sdk"
export ANDROID_SDK_ROOT="$sdk"
info "sdk: $sdk"
if [ -n "$native" ]; then
  command -v cargo >/dev/null 2>&1 || die "cargo is required for --native"
  command -v rustc >/dev/null 2>&1 || die "rustc is required for --native"
  if ! command -v cargo-ndk >/dev/null 2>&1; then
    info "installing cargo-ndk"
    cargo install cargo-ndk --locked --quiet || die "could not install cargo-ndk"
  fi
  ndk=""
  for cand in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
    if [ -n "$cand" ] && [ -d "$cand" ]; then ndk="$cand"; break; fi
  done
  if [ -z "$ndk" ]; then
    for cand in "$sdk"/ndk/*; do
      if [ -d "$cand" ]; then ndk="$cand"; break; fi
    done
  fi
  [ -n "$ndk" ] && [ -d "$ndk" ] || die "no NDK found under $sdk/ndk"
  export ANDROID_NDK_HOME="$ndk"
  info "ndk: $ndk"
  manifest="$(find "$srcdir" -maxdepth 4 -path '*/src/main/AndroidManifest.xml' 2>/dev/null | head -1)"
  [ -n "$manifest" ] || die "no app module (src/main/AndroidManifest.xml) found"
  mod_dir="$(dirname "$(dirname "$(dirname "$manifest")")")"
  dest="$mod_dir/src/main/jniLibs"
  crate="$(awk -F'"' '/^name *=/ { print $2; exit }' "$srcdir/$native/Cargo.toml")"
  [ -n "$crate" ] || die "could not read crate name from $native/Cargo.toml"
  lib="$(printf '%s' "$crate" | tr '-' '_')"
  triple_for() {
    case "$1" in
      arm64-v8a) printf aarch64-linux-android ;;
      armeabi-v7a) printf armv7-linux-androideabi ;;
      x86_64) printf x86_64-linux-android ;;
      x86) printf i686-linux-android ;;
    esac
  }
  tflags="$(printf '%s' "$abis" | sed 's/^/-t /; s/,/ -t /g')"
  (cd "$srcdir/$native" && cargo ndk $tflags --platform 28 build --release)
  for _abi in $(printf '%s' "$abis" | tr ',' ' '); do
    triple="$(triple_for "$_abi")"
    src_so="$(find "$srcdir/$native/target/$triple/release" -maxdepth 1 -name "lib${lib}.so" 2>/dev/null | head -1)"
    [ -n "$src_so" ] || die "no lib${lib}.so for $triple"
    mkdir -p "$dest/$_abi"
    cp "$src_so" "$dest/$_abi/"
    info "staged $dest/$_abi/lib${lib}.so"
  done
fi
signing_tmp=""
gradle_home_tmp=""
cleanup_signing() {
  if [ -n "$signing_tmp" ] && [ -d "$signing_tmp" ]; then
    find "$signing_tmp" -type f -exec shred -u {} + 2>/dev/null || find "$signing_tmp" -type f -delete 2>/dev/null || true
    rm -rf "$signing_tmp"
  fi
  if [ -n "$gradle_home_tmp" ] && [ -d "$gradle_home_tmp" ]; then
    rm -rf "$gradle_home_tmp"
  fi
}
expected_fp=""
if [ "$signed" = "true" ]; then
  env_file="${FBT_SIGNING_ENV:-$HOME/.config/fbt/signing.env}"
  s_keystore=""; s_store_pass=""; s_alias=""; s_key_pass=""
  if [ -f "$env_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      k="${line%%=*}"
      v="${line#*=}"
      case "$k" in
        RELEASE_KEYSTORE_PATH) s_keystore="$v" ;;
        RELEASE_KEYSTORE_PASSWORD|RELEASE_STORE_PASSWORD) s_store_pass="$v" ;;
        RELEASE_KEY_ALIAS) s_alias="$v" ;;
        RELEASE_KEY_PASSWORD) s_key_pass="$v" ;;
      esac
    done < "$env_file"
  fi
  ks_path="${FBT_KEYSTORE:-${s_keystore:-}}"
  ks_pass="${FBT_KEYSTORE_PASSWORD:-${s_store_pass:-}}"
  key_alias="${FBT_KEY_ALIAS:-${s_alias:-}}"
  key_pass="${FBT_KEY_PASSWORD:-${s_key_pass:-}}"
  [ -z "$key_pass" ] && key_pass="$ks_pass"
  [ -n "$ks_path" ] || die "no release keystore configured (run fbt-local keygen)"
  [ -f "$ks_path" ] || die "keystore not found: $ks_path"
  [ -n "$ks_pass" ] || die "no keystore password recorded"
  [ -n "$key_alias" ] || die "no key alias recorded"
  signing_tmp="$(mktemp -d)"
  chmod 700 "$signing_tmp"
  gradle_home_tmp="$(mktemp -d)"
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g'; }
  {
    printf 'android.injected.signing.store.file=%s\n' "$ks_path"
    printf 'android.injected.signing.store.password=%s\n' "$(esc "$ks_pass")"
    printf 'android.injected.signing.key.alias=%s\n' "$key_alias"
    printf 'android.injected.signing.key.password=%s\n' "$(esc "$key_pass")"
    printf 'RELEASE_STORE_FILE=%s\n' "$ks_path"
    printf 'RELEASE_STORE_PASSWORD=%s\n' "$(esc "$ks_pass")"
    printf 'RELEASE_KEY_ALIAS=%s\n' "$key_alias"
    printf 'RELEASE_KEY_PASSWORD=%s\n' "$(esc "$key_pass")"
  } > "$gradle_home_tmp/gradle.properties"
  chmod 600 "$gradle_home_tmp/gradle.properties"
  export GRADLE_USER_HOME="$gradle_home_tmp"
  if command -v keytool >/dev/null 2>&1; then
    expected_fp="$(keytool -list -v -keystore "$ks_path" -storepass "$ks_pass" -alias "$key_alias" 2>/dev/null | awk '/SHA256:/ { l=$0; sub(/.*SHA256:[[:space:]]*/, "", l); gsub(/[:[:space:]]/, "", l); print tolower(l); exit }')"
  fi
  if [ -z "$expected_fp" ] && command -v openssl >/dev/null 2>&1; then
    expected_fp="$(openssl pkcs12 -in "$ks_path" -passin "pass:$ks_pass" -nokeys -clcerts 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z')"
  fi
  [ -n "$expected_fp" ] || { cleanup_signing; die "could not read keystore cert"; }
  info "signing cert SHA-256 $expected_fp"
  trap cleanup_signing EXIT
fi
cap="$(printf '%s' "${variant:0:1}" | tr '[:lower:]' '[:upper:]')${variant:1}"
task="assemble${cap}"
info "running $task"
(cd "$srcdir" && "$gradle_cmd" --no-daemon --stacktrace "$task")
mkdir -p "$distdir"
best=""
for a in $(find "$srcdir" -name '*.apk' -type f -not -path '*/.gradle/*' 2>/dev/null | sort); do
  case "$a" in *"$variant"*) best="$a" ;; esac
  if [ -z "$best" ]; then best="$a"; fi
done
[ -n "$best" ] || { cleanup_signing; die "build succeeded but produced no APK"; }
cp "$best" "$distdir/${project}-${variant}.apk"
info "apk: $distdir/${project}-${variant}.apk"
if [ "$signed" = "true" ]; then
  signer=""
  for s in "$sdk"/build-tools/*/apksigner; do
    [ -x "$s" ] && signer="$s"
  done
  if [ -z "$signer" ]; then
    info "warning: no apksigner under $sdk/build-tools, skipping verification"
  else
    "$signer" verify --verbose --print-certs "$distdir/${project}-${variant}.apk" || { cleanup_signing; die "apk is not signed"; }
    got="$("$signer" verify --print-certs "$distdir/${project}-${variant}.apk" | awk '/certificate SHA-256 digest:/ {print tolower($NF)}' | grep -E '^[0-9a-f]{64}$' | sort -u)"
    if [ "$got" != "$expected_fp" ]; then
      cleanup_signing
      die "signed with the wrong key (expected $expected_fp got $got)"
    fi
    info "signer cert verified"
  fi
fi
cleanup_signing
trap - EXIT
ls -l "$distdir"
