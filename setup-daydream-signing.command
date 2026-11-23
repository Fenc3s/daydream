#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SIGNING_DIRECTORY="$SCRIPT_DIR/.daydream-signing"
readonly SIGNING_ARCHIVE="$SIGNING_DIRECTORY/daydream-local-code-signing.p12"
readonly FINGERPRINT_FILE="$SIGNING_DIRECTORY/daydream-local-code-signing.sha1"
readonly IDENTITY_NAME="Daydream Local Code Signing"
readonly LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/daydream-signing.XXXXXX")"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

prompt_for_secret() {
    local prompt_text="$1"

    /usr/bin/osascript - "$prompt_text" <<'APPLESCRIPT'
on run arguments
    set promptText to item 1 of arguments
    set dialogResult to display dialog promptText default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with title "Daydream Signing"
    return text returned of dialogResult
end run
APPLESCRIPT
}

normalize_fingerprint() {
    tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]'
}

certificate_fingerprint() {
    /usr/bin/openssl x509 -in "$1" -noout -fingerprint -sha1 \
        | /usr/bin/sed 's/^[^=]*=//' \
        | normalize_fingerprint
}

identity_is_available() {
    local fingerprint="$1"

    /usr/bin/security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
        | /usr/bin/awk -v fingerprint="$fingerprint" \
            '$2 == fingerprint && $0 !~ /CSSMERR_/ { found = 1 } END { exit(found ? 0 : 1) }'
}

mkdir -p "$SIGNING_DIRECTORY"
chmod 700 "$SIGNING_DIRECTORY"

if [[ -f "$FINGERPRINT_FILE" ]]; then
    existing_fingerprint="$(normalize_fingerprint < "$FINGERPRINT_FILE")"
    if [[ -n "$existing_fingerprint" ]] && identity_is_available "$existing_fingerprint"; then
        print -- "The shared Daydream signing identity is already installed."
        print -- "Identity: $IDENTITY_NAME ($existing_fingerprint)"
        exit 0
    fi
fi

password_file="$WORK_DIRECTORY/archive-password"
certificate_file="$WORK_DIRECTORY/certificate.pem"
: > "$password_file"
chmod 600 "$password_file"

if [[ ! -f "$SIGNING_ARCHIVE" ]]; then
    print -- "No shared signing archive was found. Creating the identity for the first Mac..."
    archive_password="$(prompt_for_secret "Create a password of at least 12 characters for the shared Daydream signing archive.")" || {
        print -u2 -- "Error: Signing setup was cancelled."
        exit 1
    }
    confirmation_password="$(prompt_for_secret "Enter the same archive password again.")" || {
        print -u2 -- "Error: Signing setup was cancelled."
        exit 1
    }

    if [[ ${#archive_password} -lt 12 ]]; then
        print -u2 -- "Error: The signing archive password must contain at least 12 characters."
        exit 1
    fi
    if [[ "$archive_password" != "$confirmation_password" ]]; then
        print -u2 -- "Error: The signing archive passwords do not match."
        exit 1
    fi

    print -rn -- "$archive_password" > "$password_file"
    unset confirmation_password

    private_key_file="$WORK_DIRECTORY/private-key.pem"
    archive_candidate="$WORK_DIRECTORY/daydream-local-code-signing.p12"

    /usr/bin/openssl req \
        -new \
        -newkey rsa:3072 \
        -x509 \
        -sha256 \
        -days 3650 \
        -nodes \
        -subj "/CN=$IDENTITY_NAME/O=Daydream Local Development" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$private_key_file" \
        -out "$certificate_file" >/dev/null 2>&1

    /usr/bin/openssl pkcs12 \
        -export \
        -inkey "$private_key_file" \
        -in "$certificate_file" \
        -name "$IDENTITY_NAME" \
        -passout "file:$password_file" \
        -out "$archive_candidate"

    fingerprint="$(certificate_fingerprint "$certificate_file")"
    print -r -- "$fingerprint" > "$WORK_DIRECTORY/daydream-local-code-signing.sha1"
    chmod 600 "$archive_candidate"
    chmod 644 "$WORK_DIRECTORY/daydream-local-code-signing.sha1"
    /bin/mv "$archive_candidate" "$SIGNING_ARCHIVE"
    /bin/mv "$WORK_DIRECTORY/daydream-local-code-signing.sha1" "$FINGERPRINT_FILE"

    print -- "Created the encrypted signing archive at:"
    print -- "$SIGNING_ARCHIVE"
else
    print -- "Found the shared signing archive. Importing it for this Mac..."
    archive_password="$(prompt_for_secret "Enter the password for the shared Daydream signing archive.")" || {
        print -u2 -- "Error: Signing setup was cancelled."
        exit 1
    }
    print -rn -- "$archive_password" > "$password_file"

    if ! /usr/bin/openssl pkcs12 \
        -in "$SIGNING_ARCHIVE" \
        -clcerts \
        -nokeys \
        -passin "file:$password_file" \
        -out "$certificate_file" >/dev/null 2>&1; then
        print -u2 -- "Error: The signing archive password is incorrect or the archive is invalid."
        exit 1
    fi

    fingerprint="$(certificate_fingerprint "$certificate_file")"
    if [[ -f "$FINGERPRINT_FILE" ]]; then
        recorded_fingerprint="$(normalize_fingerprint < "$FINGERPRINT_FILE")"
        if [[ "$fingerprint" != "$recorded_fingerprint" ]]; then
            print -u2 -- "Error: The signing archive does not match its recorded certificate fingerprint."
            exit 1
        fi
    else
        print -r -- "$fingerprint" > "$FINGERPRINT_FILE"
        chmod 644 "$FINGERPRINT_FILE"
    fi
fi

if [[ ! -s "$certificate_file" ]]; then
    /usr/bin/openssl pkcs12 \
        -in "$SIGNING_ARCHIVE" \
        -clcerts \
        -nokeys \
        -passin "file:$password_file" \
        -out "$certificate_file" >/dev/null 2>&1
fi

print -- "Importing the signing identity into the login keychain..."
/usr/bin/security import "$SIGNING_ARCHIVE" \
    -k "$LOGIN_KEYCHAIN" \
    -P "$archive_password" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

print -- "Trusting the local code-signing certificate for this user..."
/usr/bin/security add-trusted-cert \
    -r trustRoot \
    -k "$LOGIN_KEYCHAIN" \
    "$certificate_file"

unset archive_password

if ! identity_is_available "$fingerprint"; then
    print -u2 -- "Error: The imported certificate is not available as a trusted code-signing identity."
    print -u2 -- "Open Keychain Access, verify the certificate trust, and run this command again."
    exit 1
fi

print -- ""
print -- "Daydream signing setup completed successfully."
print -- "Identity: $IDENTITY_NAME ($fingerprint)"
print -- "Run ./install-daydream.command to build and install Daydream."
