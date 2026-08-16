#!/usr/bin/env bash
set -euo pipefail

FORK="${1:-KernelSU}"
echo "Preparing Manager build for KSU fork: ${FORK}"

case "$FORK" in
  "xxKSU"|"KSU-Next")
    URL="https://github.com/rifs28/KernelSU-Next.git"
    ;;
  "SUKISU")
    URL="https://github.com/SukiSU-Ultra/SukiSU-Manager.git"
    ;;
  "ReSuKISU"|"ReSukiSU")
    URL="https://github.com/ReSukiSU/ReSukiSU.git"
    ;;
  *)
    URL="https://github.com/tiann/KernelSU.git"
    ;;
esac

rm -rf manager-src
echo "Cloning upstream manager source: $URL"
git clone --depth=1 --recurse-submodules "$URL" manager-src
UPSTREAM_COMMIT=$(git -C manager-src rev-parse HEAD)
echo "Manager upstream commit: $UPSTREAM_COMMIT"

GW_FILE=$(find manager-src -maxdepth 3 -name gradlew -type f | head -n 1)
if [ -z "$GW_FILE" ]; then
  echo "Error: gradlew not found in upstream source" >&2
  exit 1
fi

GW_DIR=$(dirname "$GW_FILE")
cd "$GW_DIR"
chmod +x gradlew

# Preserve upstream manager compatibility checks and signing behavior. In particular,
# do not rewrite Kernels.kt and do not create an arbitrary CI signing identity.
echo "Building unmodified upstream manager release..."
./gradlew assembleRelease --no-daemon

APK_DIR="app/build/outputs/apk/release"
FOUND_APK=$(find "$APK_DIR" -type f -name '*.apk' ! -name '*armeabi*' ! -name '*x86*' | sort | head -n 1)
if [ -z "$FOUND_APK" ] || [ ! -f "$FOUND_APK" ]; then
  echo "Error: no ARM64/universal release APK produced" >&2
  exit 1
fi

mkdir -p "$GITHUB_WORKSPACE/output_apk"
FINAL_APK_PATH="$GITHUB_WORKSPACE/output_apk/${FORK}_Manager-upstream-release.apk"
cp "$FOUND_APK" "$FINAL_APK_PATH"
sha256sum "$FINAL_APK_PATH" > "${FINAL_APK_PATH}.sha256"
printf '%s\n' "$URL/commit/$UPSTREAM_COMMIT" > "$GITHUB_WORKSPACE/output_apk/manager_upstream_commit.txt"

echo "Manager artifact copied without CI re-signing: $FINAL_APK_PATH"
echo "Runtime/installability depends on the signing configuration supplied by upstream."
