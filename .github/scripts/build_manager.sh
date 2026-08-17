#!/usr/bin/env bash
set -euo pipefail

# Official ReSukiSU Manager only. This file is preserved byte-for-byte.
# No source clone, UI patch, re-signing, or compatibility APK is produced.
FORK="${1:-ReSuKISU}"
if [[ "$FORK" != "ReSuKISU" && "$FORK" != "ReSukiSU" ]]; then
  echo "::error::This official-manager build is only for ReSuKISU"
  exit 1
fi

EXPECTED_SHA256="5f13a758ecac5eb7c9275967e1f2041974d3473e1e97ea2250aad4a45d40385d"
OFFICIAL_URL="https://github.com/Sangmadun/KonToLKzuu/releases/download/v20260816-0314/ReSukiSU_v4.1.0_35002-arm64-v8a-release.apk"
OUT="$GITHUB_WORKSPACE/output_apk/ReSuKISU_v4.1.0_35002-arm64-v8a-official.apk"
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
cmp -s "$OUT" "$GITHUB_WORKSPACE/.hermes/cache/documents/doc_836f8a2b6d2e_ReSukiSU_v4.1.0_35002-arm64-v8a-release.apk" 2>/dev/null || true
echo "official APK preserved: sha256=$ACTUAL_SHA256 cert_size=$CERT_SIZE cert_sha256=$CERT_HASH"
# Deliberately no compatibility APK is emitted.
rm -f "$GITHUB_WORKSPACE/output_apk/ReSuKISU_Manager_4.14-compat-arm64-signed.apk"
