#!/bin/zsh
# One-time: creates the local signing identity used by build.sh (self-signed, John's Mac only).
# Lives in its own keychain so no password prompt ever appears. Nothing here leaves the Mac.
set -euo pipefail
SUPPORT="$HOME/Library/Application Support/Audrey Mail"
KC="$SUPPORT/signing.keychain-db"
[ -f "$KC" ] && { echo "already set up"; exit 0; }
mkdir -p "$SUPPORT"; umask 077
T=$(mktemp -d)
cat > "$T/cs.cnf" <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Audrey Mail Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3650 -config "$T/cs.cnf"
openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/c.p12" -passout pass:tmp -legacy
openssl rand -hex 16 > "$SUPPORT/signing.pw"
PW=$(cat "$SUPPORT/signing.pw")
security create-keychain -p "$PW" "$KC"; security set-keychain-settings "$KC"; security unlock-keychain -p "$PW" "$KC"
security import "$T/c.p12" -k "$KC" -P tmp -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
rm -r "$T"
echo "signing identity ready"
