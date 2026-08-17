#!/usr/bin/env bash
set -e

KERNEL_DEFCONFIG="$1"
ARCH="${2:-arm64}"

cd kernel-source

# The Manager certificate is paired immediately before this build. Do not
# reuse stale KSU objects or an old boot image from a prior output tree.
rm -rf out
export CCACHE_DISABLE=1

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

set_config "CONFIG_KPROBES" "y" "$DEFCONFIG_FILE"
set_config "CONFIG_HAVE_KPROBES" "y" "$DEFCONFIG_FILE"
set_config "CONFIG_KPROBE_EVENTS" "y" "$DEFCONFIG_FILE"
set_config "CONFIG_KSU" "y" "$DEFCONFIG_FILE"

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
