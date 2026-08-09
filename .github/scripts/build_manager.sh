#!/usr/bin/env bash
set -e

FORK="${1:-KernelSU}"
echo "🚀 Preparing Manager build for KSU Fork: ${FORK}"

# Mapping repo URL berdasarkan KSU Fork
case "$FORK" in
  "xxKSU"|"KSU-Next")
    URLS=("https://github.com/rifs28/KernelSU-Next.git" "https://github.com/tiann/KernelSU.git")
    ;;
  "SUKISU")
    URLS=("https://github.com/SukiSU-Ultra/SukiSU-Manager.git" "https://github.com/SukiSU-Ultra/SukiSU-Ultra.git" "https://github.com/tiann/KernelSU.git")
    ;;
  "ReSuKISU"|"ReSukiSU")
    URLS=("https://github.com/ReSukiSU/ReSukiSU.git" "https://github.com/tiann/KernelSU.git")
    ;;
  *)
    URLS=("https://github.com/tiann/KernelSU.git")
    ;;
esac

# 1. Clone Repository
rm -rf manager-src
CLONED=0
for url in "${URLS[@]}"; do
  echo "📥 Attempting to clone: $url"
  if git clone --depth=1 --recurse-submodules "$url" manager-src 2>/dev/null; then
    CLONED=1
    break
  fi
done

if [ "$CLONED" -eq 0 ]; then
  echo "❌ Error: Failed to clone Manager repository!"
  exit 1
fi

# 2. Cari gradlew & Jalankan Build
GW_FILE=$(find manager-src -maxdepth 3 -name "gradlew" 2>/dev/null | head -n 1)
if [ -z "$GW_FILE" ]; then
  echo "❌ Error: gradlew file not found in manager-src!"
  exit 1
fi

GW_DIR=$(dirname "$GW_FILE")
cd "$GW_DIR"
chmod +x gradlew

echo "🏗️ Starting Gradle Build for Manager APK..."
./gradlew assembleRelease --no-daemon

# 3. Pindahkan KHUSUS APK arm64-v8a atau universal
mkdir -p "$GITHUB_WORKSPACE/output_apk"

APK_DIR="app/build/outputs/apk/release"
FOUND_APK=""

# Prioritas 1: APK Universal
if ls ${APK_DIR}/*universal*.apk 1>/dev/null 2>&1; then
  FOUND_APK=$(ls ${APK_DIR}/*universal*.apk | head -n 1)
  echo "✅ Found Universal APK: ${FOUND_APK}"
# Prioritas 2: APK khusus ARM64
elif ls ${APK_DIR}/*arm64-v8a*.apk 1>/dev/null 2>&1; then
  FOUND_APK=$(ls ${APK_DIR}/*arm64-v8a*.apk | head -n 1)
  echo "✅ Found ARM64-v8a APK: ${FOUND_APK}"
# Fallback: Ambil APK rilis apapun selain armeabi/x86 jika split tidak aktif
else
  FOUND_APK=$(find ${APK_DIR} -type f -name "*.apk" ! -name "*armeabi*" ! -name "*x86*" | head -n 1)
fi

if [ -n "$FOUND_APK" ] && [ -f "$FOUND_APK" ]; then
  FINAL_NAME="${FORK}-Manager-arm64.apk"
  cp "$FOUND_APK" "$GITHUB_WORKSPACE/output_apk/${FINAL_NAME}"
  echo "📦 Successfully copied and renamed to: output_apk/${FINAL_NAME}"
else
  echo "❌ Error: No valid ARM64 or Universal APK found after Gradle build!"
  exit 1
fi

echo "✅ Manager APK built successfully!"
