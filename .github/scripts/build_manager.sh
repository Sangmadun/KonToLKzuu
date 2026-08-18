#!/usr/bin/env bash
set -euo pipefail

# Official ReSukiSU Manager only. This file is preserved byte-for-byte.
# No source clone, UI patch, re-signing, or compatibility APK is produced.
FORK="${1:-ReSuKISU}"
if [[ "$FORK" != "ReSuKISU" && "$FORK" != "ReSukiSU" ]]; then
  echo "::error::This official-manager build is only for ReSuKISU"
  exit 1
fi

EXPECTED_SHA256="1304702a9aac86d6354ace9798eec0b1efb1b50ed6a1a8309e54680b39be0d6b"
OFFICIAL_URL="https://github.com/Sangmadun/KonToLKzuu/releases/download/resukisu-35079-official/ReSukiSU_v4.2.0-rc1_35079-arm64-v8a-release.apk"
OUT="$GITHUB_WORKSPACE/output_apk/ReSukiSU_v4.2.0-rc1_35079-arm64-v8a-official.apk"
mkdir -p "$GITHUB_WORKSPACE/output_apk"
curl -fL --retry 3 --retry-delay 2 "$OFFICIAL_URL" -o "$OUT"
test -s "$OUT"
ACTUAL_SHA256="$(sha256sum "$OUT" | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
  echo "::error::official APK SHA256 mismatch: $ACTUAL_SHA256"
  exit 1
}
printf '%s  %s\n' "$ACTUAL_SHA256" "$(basename "$OUT")" > "$OUT.sha256"
# Extract the exact APK v2 certificate metadata for the kernel allowlist.
read -r CERT_SIZE CERT_HASH < <(python3 "$GITHUB_WORKSPACE/.github/scripts/extract_apk_v2_cert.py" "$OUT")
printf '%s %s\n' "$CERT_SIZE" "$CERT_HASH" > "$OUT.cert"
echo "official APK preserved: sha256=$ACTUAL_SHA256 cert_size=$CERT_SIZE cert_sha256=$CERT_HASH"
# Deliberately no compatibility APK is emitted.
rm -f "$GITHUB_WORKSPACE/output_apk/ReSuKISU_Manager_4.14-compat-arm64-signed.apk"
