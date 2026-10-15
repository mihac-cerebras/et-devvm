#!/usr/bin/env bash
# ci/build.sh — build ET from upstream at a given commit and package the
# binaries as et-el9-x86_64.tar.gz (+ .sha256). Runs as root inside a
# rockylinux:9 container in GitHub Actions (see .github/workflows/release.yml).
#
#   ci/build.sh <upstream-sha> <out-dir>
#
# Mirrors build_from_source in install.sh; keep the cmake flags in sync.
set -euo pipefail
SHA="$1"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
SRC="${ET_SRC:-$PWD/EternalTerminal}"

if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/MisterTea/EternalTerminal "$SRC"
fi
cd "$SRC"
git checkout -- vcpkg.json 2>/dev/null || true
git fetch -q origin
git checkout -q --detach "$SHA"
git submodule update --init --recursive

# No Sentry crash reporting (same as install.sh).
sed -i '/"sentry-native",/d' vcpkg.json

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DDISABLE_SENTRY=ON
cmake --build build -j"$(nproc)"
./build/et-test

PKG="$OUT/et-el9-x86_64"
rm -rf "$PKG" && mkdir -p "$PKG"
for b in et etserver etterminal; do
    cp "build/$b" "$PKG/$b"
    strip "$PKG/$b"
    chmod 755 "$PKG/$b"
done
{
    echo "$("$PKG/etserver" --version 2>&1 | head -1)"
    echo "upstream: https://github.com/MisterTea/EternalTerminal/commit/$(git rev-parse HEAD)"
    echo "commit:   $(git log -1 --format='%h %cs %s')"
    echo "built:    $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(. /etc/os-release && echo "$PRETTY_NAME"), $(gcc --version | head -1)"
} > "$PKG/VERSION"
echo "--- shared libraries (must all exist on the target VM):"
ldd "$PKG/etserver" "$PKG/et" "$PKG/etterminal" | awk '/=>/ {print $1}' | sort -u | tee "$PKG/NEEDED"

cd "$OUT"
tar -czf et-el9-x86_64.tar.gz et-el9-x86_64
sha256sum et-el9-x86_64.tar.gz > et-el9-x86_64.tar.gz.sha256
cat et-el9-x86_64/VERSION
