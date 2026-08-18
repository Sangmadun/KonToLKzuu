#!/system/bin/sh
# Fail-safe launcher for the staged SUS_MAP-capable ReSukiSU daemon.
set -u
BASE="${KSU_BOOTSTRAP_BASE:-/data/adb/ksu-bootstrap}"
REAL="$BASE/ksud.susmap"
ACTIVE="${KSU_ACTIVE_DAEMON:-/data/adb/ksud}"
BACKUP="$BASE/ksud.previous"
MARKER="$BASE/.ksud-susmap-installed"
EXPECTED_SHA256_FILE="$BASE/ksud.sha256"
BIN_DIR="${KSU_BIN_DIR:-/data/adb/ksu/bin}"
DAEMON_LINK="$BIN_DIR/ksud"
SUSCTL="$BIN_DIR/ksu_susfs"

[ -x "$REAL" ] || exit 0
[ -s "$EXPECTED_SHA256_FILE" ] || exit 0
EXPECTED=$(awk 'NR==1 {print $1}' "$EXPECTED_SHA256_FILE" 2>/dev/null)
[ "${#EXPECTED}" -eq 64 ] || exit 0
hash_file() { sha256sum "$1" 2>/dev/null | awk 'NR==1 {print $1}'; }
[ "$(hash_file "$REAL")" = "$EXPECTED" ] || exit 0
if [ "${1:-}" != "install" ]; then
    exec "$REAL" "$@"
fi
same_inode() {
    [ -f "$1" ] && [ -f "$2" ] || return 1
    [ "$(stat -c '%d:%i' "$1" 2>/dev/null)" = "$(stat -c '%d:%i' "$2" 2>/dev/null)" ]
}
repair_links() {
    mkdir -p "$BIN_DIR" 2>/dev/null || return 1
    rm -f "$DAEMON_LINK"
    ln -s "$ACTIVE" "$DAEMON_LINK" 2>/dev/null || return 1
    [ "$(readlink "$DAEMON_LINK" 2>/dev/null)" = "$ACTIVE" ] || return 1
    if ! same_inode "$ACTIVE" "$SUSCTL"; then
        rm -f "$SUSCTL"
        ln "$ACTIVE" "$SUSCTL" 2>/dev/null || return 1
    fi
    same_inode "$ACTIVE" "$SUSCTL"
}
HAD_ACTIVE=0
restore_old() {
    if [ "$HAD_ACTIVE" -eq 1 ] && [ -s "$BACKUP" ]; then
        cp -fp "$BACKUP" "$ACTIVE" 2>/dev/null || true
        repair_links >/dev/null 2>&1 || true
    else
        rm -f "$ACTIVE" "$DAEMON_LINK" "$SUSCTL"
    fi
    rm -f "$MARKER" "$MARKER.new"
}

if [ -f "$MARKER" ] && [ -x "$ACTIVE" ] && [ "$(hash_file "$ACTIVE")" = "$EXPECTED" ]; then
    repair_links || { rm -f "$MARKER" "$MARKER.new"; exit 0; }
    exit 0
fi
rm -f "$MARKER" "$MARKER.new"
if [ -x "$ACTIVE" ]; then
    HAD_ACTIVE=1
    cp -fp "$ACTIVE" "$BACKUP" 2>/dev/null || exit 0
else
    rm -f "$BACKUP"
fi
rm -f "$DAEMON_LINK" 2>/dev/null || { restore_old; exit 0; }
if ! "$REAL" "$@"; then restore_old; exit 0; fi
if [ ! -x "$ACTIVE" ] || [ "$(hash_file "$ACTIVE")" != "$EXPECTED" ]; then restore_old; exit 0; fi
repair_links || { restore_old; exit 0; }
sync
echo "ksud_sha256=$EXPECTED" > "$MARKER.new" 2>/dev/null || exit 0
if [ -s "$BASE/libadbroot.so" ]; then
    echo "libadbroot_sha256=$(hash_file "$BASE/libadbroot.so")" >> "$MARKER.new" 2>/dev/null || true
fi
mv -f "$MARKER.new" "$MARKER" 2>/dev/null || true
exit 0
