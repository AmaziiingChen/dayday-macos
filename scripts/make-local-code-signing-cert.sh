#!/bin/zsh
# Creates (once) and returns a persistent local code-signing identity for the
# teamless Dayday dev build.
#
# macOS TCC identifies an ad-hoc (`-`) signed app by its CDHash, which changes
# after every rebuild --- so each build is a "new app" and macOS re-prompts for
# Input Monitoring / Screen Recording. Signing with one stable self-signed
# certificate keeps the CDHash identical across rebuilds, so the granted
# permissions stay valid without re-authorizing every time.
#
# The certificate is generated on first run and reused afterwards. It is a
# self-signed keychain identity (CSSMERR_TP_NOT_TRUSTED is expected and fine),
# used only by codesign; it is not a trusted/export identity in any way.
set -euo pipefail

keychain_path="${DAYDAY_SIGNING_KEYCHAIN:-$HOME/.keychains/dayday-dev.keychain-db}"
cert_name="Dayday Local Dev"
cert_dir="${DAYDAY_SIGNING_CERT_DIR:-$HOME/.dayday-local}"
p12_path="$cert_dir/identity.p12"

mkdir -p "$(dirname "$keychain_path")"
mkdir -p "$cert_dir"

# Find the running identity: it appears as "Dayday Local Dev" in the keychain.
identity=$(
  security find-identity -p codesigning "$keychain_path" 2>/dev/null \
    | awk -v n="$cert_name" '$0 ~ n { print $2 }' | head -1
)

if [[ -n "$identity" ]]; then
  echo "$cert_name:$identity:$keychain_path"
else
  if [[ ! -s "$p12_path" ]]; then
    key_file="$cert_dir/key.pem"
    crt_file="$cert_dir/cert.pem"
    openssl genrsa -out "$key_file" 2048 >/dev/null 2>&1
    openssl req -new -x509 -key "$key_file" -out "$crt_file" -days 3650 \
      -subj "/CN=$cert_name/O=Dayday/OU=Local" \
      -addext "extendedKeyUsage=codeSigning" \
      -addext "keyUsage=digitalSignature" >/dev/null 2>&1
    openssl pkcs12 -export -inkey "$key_file" -in "$crt_file" \
      -out "$p12_path" -passout pass:dayday -legacy \
      -name "$cert_name" >/dev/null 2>&1
    chmod 600 "$key_file" "$crt_file" "$p12_path"
  fi

  if [[ ! -f "$keychain_path" ]]; then
    security create-keychain -p dayday "$keychain_path"
    security set-keychain-settings -l -u -t 3600 "$keychain_path" 2>/dev/null || true
  fi
  security unlock-keychain -p dayday "$keychain_path"
  security import "$p12_path" -k "$keychain_path" -P dayday -T /usr/bin/codesign \
    >/dev/null 2>&1

  identity=$(
    security find-identity -p codesigning "$keychain_path" 2>/dev/null \
      | awk -v n="$cert_name" '$0 ~ n { print $2 }' | head -1
  )
  [[ -n "$identity" ]] || { print -u2 "Unable to create local signing identity."; exit 1; }
  print "$cert_name:$identity:$keychain_path"
fi