#!/bin/zsh
# Build, sign, package, and publish a pinned vigil release with a universal
# binary — built on our own hardware; GitHub Releases is distribution only.
# Usage: scripts/release.sh <tag>     e.g. scripts/release.sh 0.6.0
set -euo pipefail

TAG="${1:?usage: release.sh <tag>}"
DIST=".build/release-dist"
rm -rf "$DIST"; mkdir -p "$DIST"

for ARCH in arm64 x86_64; do
    echo "→ Building release binary (${ARCH})"
    swift build -c release --product vigil --arch "$ARCH"
    BIN_DIR="$(swift build -c release --product vigil --arch "$ARCH" --show-bin-path | tail -1)"
    cp "${BIN_DIR}/vigil" "$DIST/vigil-${ARCH}"
done

echo "→ Creating universal binary"
lipo -create "$DIST/vigil-arm64" "$DIST/vigil-x86_64" -output "$DIST/vigil"
codesign -s - --force --options runtime "$DIST/vigil"
tar -czf "$DIST/vigil-macos-universal.tar.gz" -C "$DIST" vigil
shasum -a 256 "$DIST/vigil-macos-universal.tar.gz"

echo "→ Publishing release ${TAG}"
gh release create "$TAG" \
    --title "swift-vigil ${TAG}" \
    --notes "Universal macOS binary (arm64 + x86_64). Built $(date -u +%Y-%m-%dT%H:%M:%SZ) at $(git rev-parse --short HEAD)." \
    "$DIST/vigil-macos-universal.tar.gz"
echo "✓ Release ${TAG} published."
