#!/usr/bin/env bash
# no-web-guard.sh - fails if the shell pulls the web build, wasm tooling or a WebView.
# Textual checks run everywhere; the `cargo tree --locked` check runs only where cargo
# exists (CI, ubuntu-24.04 preinstall). Run from the repo root. Exit 0 = clean.
set -u
fail=0
say() { printf 'NO-WEB: %s\n' "$*" >&2; }

DEP_PAT='wasm-bindgen|web-sys|js-sys|wasm-pack|photocraft-web|trunk|RUST_TARGET_WASM|wasm_target'

# 1. Manifest / cargo-config text scan (android/**).
while IFS= read -r f; do
  crlff=""
  hits="$(tr -d '\r' < "$f" | grep -Eio "$DEP_PAT" | sort -u | tr '\n' ' ')"
  if [ -n "$hits" ]; then say "$f references web/wasm tooling: $hits"; fail=1; fi
done < <(find android \( -name Cargo.toml -o \( -name config.toml -path '*cargo*' \) \) -print 2>/dev/null | sort)

# 2. Rust source scan: no wasm machinery, no target_arch = "wasm32", no js interop.
if [ -d android/src ]; then
  while IFS= read -r f; do
    hits="$(tr -d '\r' < "$f" | grep -Eio 'wasm_bindgen|wasm-bindgen|web-sys|js-sys|wasm32|JsValue|wasm::' | sort -u | tr '\n' ' ')"
    if [ -n "$hits" ]; then say "$f contains web/wasm code: $hits"; fail=1; fi
  done < <(find android/src -name '*.rs' -print 2>/dev/null | sort)
fi

# 3. Gradle/manifest scan: no WebView, no web packages.
if [ -e android/app ]; then
  while IFS= read -r f; do
    hits="$(tr -d '\r' < "$f" | grep -Eio 'android\.webkit|WebView|addJavascriptInterface|JavascriptInterface|com\.android\.tools\.build\.[a-z-]*wasm|jitpack.*wasm' | sort -u | tr '\n' ' ')"
    if [ -n "$hits" ]; then say "$f uses a WebView/web package: $hits"; fail=1; fi
  done < <(find android/app \( -name '*.gradle' -o -name '*.gradle.kts' -o -name 'AndroidManifest.xml' -o -name '*.xml' \) -print 2>/dev/null | sort)
fi

# 4. Dependency GRAPH check (needs cargo; strict when a lock exists).
if command -v cargo >/dev/null 2>&1; then
  if [ ! -f android/Cargo.lock ]; then
    say "android/Cargo.lock missing: commit the seeded lock (cargo generate-lockfile in android/)"; fail=1
  else
    tree="$(cargo tree --locked -e normal --target aarch64-linux-android --manifest-path android/Cargo.toml 2>&1)"
    if [ $? -ne 0 ]; then
      say "cargo tree --locked failed - lock is not exactly what the manifests want:"; printf '%s\n' "$tree" | head -12 >&2; fail=1
    else
      hits="$(printf '%s\n' "$tree" | grep -E '(^|[ /])(wasm-bindgen|wasm-bindgen-futures|wasm-bindgen-test|web-sys|js-sys|photocraft-web|trunk)( |$)' | head -10)"
      if [ -n "$hits" ]; then say "the dependency graph contains web/wasm packages:"; printf '%s\n' "$hits" >&2; fail=1; fi
    fi
  fi
else
  say "cargo not on PATH: graph check skipped here (runs in CI)"
fi

[ "$fail" -eq 0 ] && say "OK: no web/wasm/WebView in the shell"
exit "$fail"
