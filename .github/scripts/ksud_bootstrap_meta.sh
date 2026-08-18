#!/system/bin/sh
# ReSukiSU Android-side bootstrap. Recovery only stages these files.
set -u
BASE=/data/adb/ksu-bootstrap
KSUD="$BASE/ksud"
ADBROOT="$BASE/libadbroot.so"
META_ZIP="$BASE/meta-overlayfs-13100-1.3.1.zip"
MARKER="$BASE/.meta-overlayfs-installed"
KSUD_MARKER="$BASE/.ksud-susmap-installed"

[ -x "$KSUD" ] || exit 0
[ -s "$KSUD_MARKER" ] || exit 0
[ -f "$MARKER" ] && exit 0

# Never reinstall or overwrite an already healthy metamodule.
if [ -f /data/adb/modules/meta-overlayfs/module.prop ] && [ -L /data/adb/metamodule ]; then
    touch "$MARKER" 2>/dev/null || true
    exit 0
fi

# The preceding init-rc command installs the official userspace first.
# This script only proceeds when the final userspace is available.
if [ -x /data/adb/ksu/bin/ksud ]; then
    RUN_KSUD=/data/adb/ksu/bin/ksud
elif [ -x /data/adb/ksud ]; then
    RUN_KSUD=/data/adb/ksud
else
    exit 0
fi

# Install the official OverlayFS metamodule exactly like a Manager module.
# No marker is written on failure, so a later boot can retry safely.
[ -s "$META_ZIP" ] || exit 0
"$RUN_KSUD" module install "$META_ZIP" || exit 0
# Only mark success after KernelSU can see the metamodule metadata and its
# canonical symlink. Otherwise the next boot retries instead of hiding an
# incomplete installation behind a success marker.
[ -f /data/adb/modules/meta-overlayfs/module.prop ] || exit 0
[ -L /data/adb/metamodule ] || exit 0
sync
touch "$MARKER" 2>/dev/null || true
exit 0
