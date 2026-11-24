#!/usr/bin/env bash
# Creates Seemless's self-signed code-signing identity in your login
# keychain (Preview 1: owner, 2026-11-24, "We will use a self-sign cert for
# now"). Run it once, yourself, on the Mac that builds releases.
#
#   scripts/release/make-signing-cert.sh ["Seemless Self-Signed"]
#
# Then package with:
#   SEEMLESS_SIGN_IDENTITY="Seemless Self-Signed" scripts/package-release.sh
#
# What it does:
#   1. Makes a 2048-bit RSA key and a 10-year self-signed certificate with
#      the codeSigning extended key usage (/usr/bin/openssl, in a temporary
#      directory that is deleted afterwards).
#   2. Imports key and certificate into the login keychain, letting only
#      /usr/bin/codesign use the key without asking.
#   3. Asks macOS to trust the certificate for code signing, so
#      `security find-identity -v -p codesigning` lists it. macOS asks for
#      your password for this step; you can skip it (codesign signs with an
#      untrusted identity too).
#
# A self-signed identity has no Apple Team ID. Consequences (docs/release.md):
# the app cannot be notarized, Gatekeeper blocks it on testers' Macs until
# they allow it in System Settings, and sign-app.sh adds
# com.apple.security.cs.disable-library-validation, as for ad-hoc builds.
#
# Export for CI later (docs/ci-plan.md "Secrets and gates"); macOS asks for
# an export password, which becomes the CI secret's password:
#   security export -k login.keychain-db -t identities -f pkcs12 -o ~/Desktop/seemless-signing.p12
# (exports every identity in the keychain; pick the Seemless one in
# Keychain Access ▸ My Certificates ▸ right-click ▸ Export if you have more.)
#
# SEEMLESS_CERT_KEYCHAIN=<path> imports into another keychain instead of the
# login keychain (used to test this script with a throwaway keychain).
set -euo pipefail

name="${1:-Seemless Self-Signed}"
keychain="${SEEMLESS_CERT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
openssl=/usr/bin/openssl   # LibreSSL: its PKCS#12 defaults are ones `security import` accepts

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "A certificate named \"$name\" is already in $keychain. Nothing to do." >&2
  echo "Delete it in Keychain Access first if you want a new one." >&2
  exit 1
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
"$openssl" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
# A throwaway password only protects the temporary .p12 between these two
# commands; it is never stored or shown.
pass="$("$openssl" rand -hex 16)"
"$openssl" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
  -out "$tmp/id.p12" -passout "pass:$pass"
security import "$tmp/id.p12" -k "$keychain" -f pkcs12 -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Imported \"$name\" into $keychain."

if [[ -z "${SEEMLESS_CERT_KEYCHAIN:-}" ]]; then
  echo "Trusting it for code signing (macOS asks for your password)…"
  if security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"; then
    echo "Trusted."
  else
    echo "Not trusted (skipped or refused). codesign still works with it." >&2
  fi
fi

security find-identity -p codesigning "$keychain" | grep -F "\"$name\"" || true
echo
echo "Next: SEEMLESS_SIGN_IDENTITY=\"$name\" scripts/package-release.sh"
