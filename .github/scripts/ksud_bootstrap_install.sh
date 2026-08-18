#!/system/bin/sh
# Fail-safe launcher for the staged SUS_MAP-capable ReSukiSU daemon.
# The kernel init hook calls this exact path with: install --libadbroot PATH
set -u

BASE=/data/adb/ksu-bootstrap
REAL="$BASE/ksud.susmap"
ACTIVE=/data/adb/ksud
BACKUP="$BASE/ksud.previous"
MARKER="$BASE/.ksud-susmap-installed"
EXPECTED_SHA256_FILE="$BASE/ksud.sha256"

# Preserve normal CLI behavior if this staged launcher is invoked manually.
if [ "${1:-}" != "install" ]; then
    [ -x "$REAL" ] || exit 127
    exec "$REAL" "$@"
fi

[ -x "$REAL" ] || exit 0
[ -s "$EXPECTED_SHA256_FILE" ] || exit 0
EXPECTED=$(awk 'NR==1 {print $1}' "$EXPECTED_SHA256_FILE" 2>/dev/null)
[ "${#EXPECTED}" -eq 64 ] || exit 0

hash_file() {
    sha256sum "$1" 2>/dev/null | awk 'NR==1 {print $1}'
}

# Idempotent success path. Repair the SUSFS CLI hardlink if removed manually.
if [ -f "$MARKER" ] && [ -x "$ACTIVE" ] && [ "$(hash_file "$ACTIVE")" = "$EXPECTED" ]; then
    mkdir -p /data/adb/ksu/bin 2>/dev/null || true
    SUSCTL=/data/adb/ksu/bin/ksu_susfs
    if [ ! -e "$SUSCTL" ]; then
        ln "$ACTIVE" "$SUSCTL" 2>/dev/null || true
    fi
    exit 0
fi

rm -f "$MARKER"
if [ -x "$ACTIVE" ]; then
    cp -fp "$ACTIVE" "$BACKUP" 2>/dev/null || exit 0
fi

# Forward the original install arguments to the real pinned daemon. Its
# installer atomically replaces ACTIVE, restores labels and extracts assets.
if ! "$REAL" "$@"; then
    [ -s "$BACKUP" ] && cp -fp "$BACKUP" "$ACTIVE" 2>/dev/null || true
    exit 0
fi

# Fail closed: never mark a partial/wrong userspace as installed.
if [ ! -x "$ACTIVE" ] || [ "$(hash_file "$ACTIVE")" != "$EXPECTED" ]; then
    [ -s "$BACKUP" ] && cp -fp "$BACKUP" "$ACTIVE" 2>/dev/null || true
    exit 0
fi

# The pinned daemon should create this hardlink. Validate and repair it.
SUSCTL=/data/adb/ksu/bin/ksu_susfs
if [ ! -f "$SUSCTL" ] || [ "$(stat -c %i "$ACTIVE" 2>/dev/null)" != "$(stat -c %i "$SUSCTL" 2>/dev/null)" ]; then
    rm -f "$SUSCTL"
    ln "$ACTIVE" "$SUSCTL" 2>/dev/null || {
        [ -s "$BACKUP" ] && cp -fp "$BACKUP" "$ACTIVE" 2>/dev/null || true
        exit 0
    }
fi

sync
touch "$MARKER" 2>/dev/null || true
exit 0
