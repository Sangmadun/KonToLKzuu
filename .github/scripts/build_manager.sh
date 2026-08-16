#!/usr/bin/env bash
set -e

FORK="${1:-KernelSU}"
echo "🚀 Preparing Manager for kernel engine: ${FORK}"

# Camellia is Linux 4.14 non-GKI. The official current KernelSU manager
# targets modern GKI and cannot be truthfully advertised as compatible here.
# Use the official, signed legacy manager v0.9.5 (build 11872), whose APK
# signature is accepted by the ReSukiSU multi-manager kernel integration.
if [ "$FORK" = "ReSuKISU" ] || [ "$FORK" = "ReSukiSU" ]; then
  OFFICIAL_URL="https://github.com/tiann/KernelSU/releases/download/v0.9.5/KernelSU_v0.9.5_11872-release.apk"
  mkdir -p "$GITHUB_WORKSPACE/output_apk"
  curl -fL --retry 3 "$OFFICIAL_URL" -o "$GITHUB_WORKSPACE/output_apk/KernelSU-Official-v0.9.5-11872-arm64.apk"
  test -s "$GITHUB_WORKSPACE/output_apk/KernelSU-Official-v0.9.5-11872-arm64.apk"
  sha256sum "$GITHUB_WORKSPACE/output_apk/KernelSU-Official-v0.9.5-11872-arm64.apk" | tee "$GITHUB_WORKSPACE/output_apk/KernelSU-Official-v0.9.5-11872-arm64.apk.sha256"
  echo "✅ Official signed legacy manager downloaded; no re-signing performed."
  exit 0
fi

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

# ReSukiSU latest explicitly supports manually integrated non-GKI kernels.
# The old script tried to patch `manager-src/...` after cd-ing into that
# directory, so the patch silently missed the file and the APK kept the
# GKI-only UI gate. Patch using an absolute path and verify the result.
echo "🔧 Enabling ReSukiSU non-GKI UI path for Linux 4.14..."
KFILE="$GITHUB_WORKSPACE/$GW_DIR/app/src/main/java/com/resukisu/resukisu/Kernels.kt"
if [ ! -f "$KFILE" ]; then
  KFILE=$(find "$GITHUB_WORKSPACE/manager-src" -type f -name Kernels.kt | head -n 1)
fi
if [ -z "$KFILE" ] || [ ! -f "$KFILE" ]; then
  echo "❌ Kernels.kt not found; refusing to ship an unverified manager"
  exit 1
fi
python3 - "$KFILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '''    fun isGKI(): Boolean = when {
        major > 5 -> true
        major == 5 && patchLevel >= 10 -> true
        else -> false
    }'''
new = '''    // Camellia is Linux 4.14 non-GKI. ReSukiSU's built-in/manual
    // integration path supports it; do not classify it as unsupported in UI.
    fun isGKI(): Boolean = true'''
if old in s:
    s = s.replace(old, new, 1)
elif 'fun isGKI(): Boolean = true' not in s:
    raise SystemExit('unexpected Kernels.kt layout; no patch applied')
p.write_text(s)
PY
 grep -A4 -B2 'fun isGKI' "$KFILE"

echo "🏗️ Starting Gradle Build for Manager APK..."
./gradlew assembleRelease --no-daemon

# 3. Cari KHUSUS APK arm64-v8a atau Universal
APK_DIR="app/build/outputs/apk/release"
FOUND_APK=""

if ls ${APK_DIR}/*arm64-v8a*.apk 1>/dev/null 2>&1; then
  FOUND_APK=$(ls ${APK_DIR}/*arm64-v8a*.apk | head -n 1)
elif ls ${APK_DIR}/*universal*.apk 1>/dev/null 2>&1; then
  FOUND_APK=$(ls ${APK_DIR}/*universal*.apk | head -n 1)
else
  FOUND_APK=$(find ${APK_DIR} -type f -name "*.apk" ! -name "*armeabi*" ! -name "*x86*" | head -n 1)
fi

if [ -z "$FOUND_APK" ] || [ ! -f "$FOUND_APK" ]; then
  echo "❌ Error: No valid ARM64 or Universal APK found!"
  exit 1
fi

echo "📦 Target Unsigned APK found: ${FOUND_APK}"

# 4. Buat Keystore Sementara & Sign APK
echo "🔑 Generating release key and signing APK..."
keytool -genkeypair -v -keystore release.keystore -alias releasekey -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass android -keypass android -dname "CN=Android,OU=Android,O=Android,L=Android,ST=Android,C=US" 2>/dev/null || true

# Cari apksigner dari Android SDK bawaan GitHub Runner
APKSIGNER=$(find $ANDROID_HOME/build-tools/ -name "apksigner" 2>/dev/null | sort -V | tail -n 1)

mkdir -p "$GITHUB_WORKSPACE/output_apk"
FINAL_APK_PATH="$GITHUB_WORKSPACE/output_apk/${FORK}_Manager_arm64-signed.apk"

if [ -n "$APKSIGNER" ] && [ -x "$APKSIGNER" ]; then
  echo "⚙️ Signing using apksigner ($APKSIGNER)..."
  "$APKSIGNER" sign --ks release.keystore --ks-pass pass:android --key-pass pass:android --out "$FINAL_APK_PATH" "$FOUND_APK"
else
  echo "⚠️ apksigner not found, signing using jarsigner..."
  cp "$FOUND_APK" "$FINAL_APK_PATH"
  jarsigner -keystore release.keystore -storepass android -keypass android "$FINAL_APK_PATH" releasekey
fi

echo "✅ Signed ARM64 Manager APK created successfully: ${FINAL_APK_PATH}"
