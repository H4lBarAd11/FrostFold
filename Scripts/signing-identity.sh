#!/usr/bin/env bash
# Creates a self-signed code-signing identity for FrostFold, once, without any
# GUI prompts.
#
# Why: an ad-hoc signature has no identity, so the requirement macOS records for
# the Screen Recording grant is the code hash itself. Any source change produces
# a new hash and macOS asks for the permission again — and every release you
# ship makes your users re-grant too. Signing with a certificate makes the
# requirement key on the certificate instead, so the grant survives rebuilds and
# updates.
#
# It lives in its own keychain rather than your login keychain. The login
# keychain gates key access behind an interactive "allow codesign to use this
# key?" dialog that cannot be answered from a script; a keychain we create has a
# password we know, so we can authorise codesign directly.
#
# This is not a substitute for a Developer ID: it does not get you notarisation,
# so a downloaded copy still needs right-click -> Open the first time.
set -euo pipefail

NAME="FrostFold Self-Signed"
KEYCHAIN_NAME="frostfold-signing.keychain"
KEYCHAIN="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
# Guards a throwaway development signing key and nothing else, which is why it
# can sit here in plain sight.
PASSWORD="frostfold"

# macOS's own LibreSSL writes a PKCS#12 that `security` can read. OpenSSL 3
# (Homebrew's, often first on PATH) defaults to an AES/SHA-256 MAC the keychain
# rejects with "MAC verification failed".
OPENSSL=/usr/bin/openssl

if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$NAME"; then
    echo "Already present: $NAME"
    security find-identity -p codesigning "$KEYCHAIN" | grep -F "$NAME" | sed 's/^/  /'
    exit 0
fi

if [ ! -f "$KEYCHAIN" ]; then
    echo "==> Creating keychain $KEYCHAIN_NAME"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN_NAME"
fi

# No auto-lock, so builds don't start failing after an idle period.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = FrostFold Self-Signed
O  = FrostFold

[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

echo "==> Generating a code-signing certificate (valid 10 years)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The transport password protects only this temp file, which is deleted on exit.
# It has to be non-empty: `security` rejects an empty-password PKCS#12 with
# "MAC verification failed".
"$OPENSSL" pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout pass:frostfold 2>/dev/null

echo "==> Importing"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P frostfold -A -T /usr/bin/codesign

# Without this, the first codesign run raises the GUI dialog regardless of the
# ACL set above. Because we know this keychain's password, we can grant it here.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo
echo "Done. Scripts/bundle.sh will pick this up automatically."
security find-identity -p codesigning "$KEYCHAIN" | grep -F "$NAME" | sed 's/^/  /'
echo
echo "To remove it later:  security delete-keychain $KEYCHAIN_NAME"
