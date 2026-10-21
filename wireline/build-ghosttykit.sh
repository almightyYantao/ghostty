#!/bin/bash
# GhosttyKit.xcframework build from the Wireline fork (this repo, branch `wireline`).
#
#   wireline/build-ghosttykit.sh [out_dir]      (env: TARGET=native|universal, ALLOW_DIRTY=1)
#
# Builds from the current checkout (no fetch). Produces in out_dir (default wireline/out):
#   GhosttyKit.xcframework/                 static libghostty-internal.a + ghostty.h + modulemap
#   GhosttyKit.xcframework.zip + .sha256    SwiftPM binaryTarget(url:checksum:) input
#   share/ghostty, share/terminfo           runtime resources for Contents/Resources
#   GHOSTTY-LICENSE, BUILD-INFO.txt         fork commit, upstream base, zig, xcode, sha256s
#
# Always built with -Dsentry=false: no Sentry SDK, no crash signal handlers in the host app.
set -euo pipefail

ZIG_REQUIRED="0.17.0"
TARGET="${TARGET:-native}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$SRC/wireline/out}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

zig_ver="$(zig version 2>/dev/null || true)"
if [[ "$zig_ver" != "$ZIG_REQUIRED" ]]; then
  echo "need zig $ZIG_REQUIRED (have '${zig_ver:-none}'): brew install zig, or ziglang.org tarball" >&2
  exit 1
fi

dirty="$(git -C "$SRC" status --porcelain --untracked-files=no)"
if [[ -n "$dirty" && "${ALLOW_DIRTY:-0}" != 1 ]]; then
  echo "working tree has uncommitted changes (set ALLOW_DIRTY=1 to build anyway):" >&2
  echo "$dirty" >&2
  exit 1
fi
rev="$(git -C "$SRC" rev-parse HEAD)"
upstream_base="$(git -C "$SRC" merge-base HEAD origin/main 2>/dev/null || echo unknown)"

start=$(date +%s)
(
  cd "$SRC"
  rm -rf macos/GhosttyKit.xcframework
  zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dsentry=false \
    -Dxcframework-target="$TARGET"
)
echo "zig build took $(( $(date +%s) - start ))s"

rm -rf "$OUT/GhosttyKit.xcframework" "$OUT/share"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$OUT/"
mkdir -p "$OUT/share/ghostty"
cp -R "$SRC/zig-out/share/ghostty/shell-integration" "$SRC/zig-out/share/ghostty/themes" "$OUT/share/ghostty/"
cp -R "$SRC/zig-out/share/terminfo" "$OUT/share/"
cp "$SRC/LICENSE" "$OUT/GHOSTTY-LICENSE"

(cd "$OUT" && rm -f GhosttyKit.xcframework.zip && ditto -c -k --keepParent GhosttyKit.xcframework GhosttyKit.xcframework.zip)
sum=$(cd "$OUT" && swift package compute-checksum "$OUT/GhosttyKit.xcframework.zip" 2>/dev/null || shasum -a 256 "$OUT/GhosttyKit.xcframework.zip" | cut -d' ' -f1)
echo "$sum" > "$OUT/GhosttyKit.xcframework.zip.sha256"

{
  echo "fork_rev=$rev${dirty:+ (dirty)}"
  echo "fork_branch=$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
  echo "upstream_base=$upstream_base"
  echo "fork_commits:"
  git -C "$SRC" log --format='  %h %s' "${upstream_base}..HEAD" 2>/dev/null || true
  echo "target=$TARGET optimize=ReleaseFast sentry=false"
  echo "zig=$(zig version)"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
  echo "built_at=$(date -u +%FT%TZ)"
  echo "zip_sha256=$sum"
  find "$OUT/GhosttyKit.xcframework" -name '*.a' -exec shasum -a 256 {} \;
  du -sh "$OUT/GhosttyKit.xcframework" "$OUT/GhosttyKit.xcframework.zip" "$OUT/share"
} | tee "$OUT/BUILD-INFO.txt"
