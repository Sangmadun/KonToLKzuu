#!/usr/bin/env bash
set -e

KERNEL_DEFCONFIG="$1"
ARCH="${2:-arm64}"

cd kernel-source

# Patching Defconfig
DEFCONFIG_FILE="arch/arm64/configs/${KERNEL_DEFCONFIG}"
set_config() {
  local config=$1
  local value=$2
  local file=$3
  if grep -q "^# $config is not set" "$file"; then
    sed -i "s/^# $config is not set/$config=$value/" "$file"
  elif grep -q "^$config=" "$file"; then
    sed -i "s/^$config=.*/$config=$value/" "$file"
  else
    echo "$config=$value" >> "$file"
  fi
}

# Manual ReSukiSU input hooks require KPROBES disabled to avoid accidental
# safe-mode triggers on volume-down during boot. Never override the audited
# camellia defconfig here.
set_config "CONFIG_KPROBES" "n" "$DEFCONFIG_FILE"
set_config "CONFIG_KSU" "y" "$DEFCONFIG_FILE"
set_config "CONFIG_DEBUG_INFO" "y" "$DEFCONFIG_FILE"
set_config "CONFIG_DEBUG_INFO_BTF" "y" "$DEFCONFIG_FILE"

# This vendor 4.14 tree contains the BTF implementation and Kconfig, but its
# older link-vmlinux.sh defines gen_btf() without ever invoking it. Add the
# missing upstream-style generation/link step before KALLSYMS. Without this,
# CONFIG_DEBUG_INFO_BTF=y is misleading and vmlinux has no .BTF section.
python3 - <<'PY'
from pathlib import Path
p = Path("scripts/link-vmlinux.sh")
s = p.read_text()
marker = 'if [ -n "${CONFIG_KALLSYMS}" ]; then\n'
block = '''btf_vmlinux_bin_o=""
if [ -n "${CONFIG_DEBUG_INFO_BTF}" ]; then
	btf_vmlinux_bin_o=.btf.vmlinux.bin.o
	vmlinux_link .tmp_vmlinux_btf
	gen_btf .tmp_vmlinux_btf "${btf_vmlinux_bin_o}"
	rm -f .tmp_vmlinux_btf
fi

'''
if block not in s:
    if marker not in s:
        raise SystemExit("KALLSYMS insertion marker missing in link-vmlinux.sh")
    s = s.replace(marker, block + marker, 1)
p.write_text(s)
PY

grep -q 'btf_vmlinux_bin_o=.btf.vmlinux.bin.o' scripts/link-vmlinux.sh || {
  echo '::error::BTF link step was not installed'; exit 1;
}

# Prepare Toolchain & Ccache
rm -f "$GITHUB_WORKSPACE/toolchain/clang/bin/ld"
export PATH="$GITHUB_WORKSPACE/toolchain/clang/bin:$GITHUB_WORKSPACE/toolchain/gcc64/bin:$GITHUB_WORKSPACE/toolchain/gcc32/bin:$PATH"
export CCACHE_DIR=~/.cache/ccache

# ------------------------------------------ 
export KBUILD_BUILD_USER="root"
export KBUILD_BUILD_HOST="rwxrxrx"
#  ------------------------------------------ 

ccache -M 5G
ccache -o compression=true
ccache -z

echo "🚀 Compiling Kernel..."
make O=out ARCH="$ARCH" "$KERNEL_DEFCONFIG"
make -j$(nproc --all) O=out \
  ARCH="$ARCH" \
  CC="ccache clang" \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE=aarch64-linux-android- \
  CROSS_COMPILE_ARM32=arm-linux-androideabi- \
  LD=ld.lld

echo "=================================================="
echo "📊 CCACHE STATS"
echo "=================================================="
ccache -s
