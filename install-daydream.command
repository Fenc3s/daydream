#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROJECT_PATH="$SCRIPT_DIR/daydream.xcodeproj"
readonly SCHEME="daydream"
readonly APP_NAME="daydream"
readonly BUNDLE_IDENTIFIER="com.daydream.app"
readonly INSTALL_PATH="/Applications/$APP_NAME.app"
readonly HOST_ARCHITECTURE="$(uname -m)"
readonly SIGNING_DIRECTORY="$SCRIPT_DIR/.daydream-signing"
readonly FINGERPRINT_FILE="$SIGNING_DIRECTORY/daydream-local-code-signing.sha1"
readonly LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

readonly PBXPROJ_PATH="$PROJECT_PATH/project.pbxproj"

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daydream-build.XXXXXX")"
PBXPROJ_BACKUP=""
BUILD_COMPLETED=0

cleanup() {
    if [[ "$BUILD_COMPLETED" -eq 0 && -n "$PBXPROJ_BACKUP" && -f "$PBXPROJ_BACKUP" ]]; then
        /bin/cp "$PBXPROJ_BACKUP" "$PBXPROJ_PATH"
    fi
    rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

find_gh_cli() {
    if command -v gh >/dev/null 2>&1; then
        command -v gh
        return
    fi
    local candidate
    for candidate in /opt/homebrew/bin/gh /usr/local/bin/gh; do
        if [[ -x "$candidate" ]]; then
            print -r -- "$candidate"
            return
        fi
    done
    return 1
}

is_complete_developer_dir() {
    [[ -x "$1/usr/bin/xcodebuild" && -d "$1/Platforms/MacOSX.platform" ]]
}

find_developer_dir() {
    if [[ -n "${DEVELOPER_DIR:-}" ]] && is_complete_developer_dir "$DEVELOPER_DIR"; then
        print -r -- "$DEVELOPER_DIR"
        return
    fi

    local active_developer_dir
    active_developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if is_complete_developer_dir "$active_developer_dir"; then
        print -r -- "$active_developer_dir"
        return
    fi

    local xcode_app
    for xcode_app in /Applications/Xcode*.app(N); do
        if is_complete_developer_dir "$xcode_app/Contents/Developer"; then
            print -r -- "$xcode_app/Contents/Developer"
            return
        fi
    done

    return 1
}

if [[ ! -d "$PROJECT_PATH" ]]; then
    print -u2 -- "Error: Xcode project not found at $PROJECT_PATH"
    exit 1
fi

if [[ ! -f "$FINGERPRINT_FILE" ]]; then
    print -u2 -- "Error: The shared Daydream signing identity has not been configured."
    print -u2 -- "Run ./setup-daydream-signing.command once on this Mac, then retry the installation."
    exit 1
fi

SIGNING_FINGERPRINT="$(tr -d ':[:space:]' < "$FINGERPRINT_FILE" | tr '[:lower:]' '[:upper:]')"
if [[ -z "$SIGNING_FINGERPRINT" ]]; then
    print -u2 -- "Error: The shared Daydream signing fingerprint is empty."
    exit 1
fi

if ! /usr/bin/security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
    | /usr/bin/awk -v fingerprint="$SIGNING_FINGERPRINT" \
        '$2 == fingerprint && $0 !~ /CSSMERR_/ { found = 1 } END { exit(found ? 0 : 1) }'; then
    print -u2 -- "Error: The shared Daydream signing identity is not available on this Mac."
    print -u2 -- "Run ./setup-daydream-signing.command to import it from the iCloud-synced archive."
    exit 1
fi

DEVELOPER_DIR="$(find_developer_dir)" || {
    print -u2 -- "Error: A complete Xcode installation was not found in /Applications."
    exit 1
}
export DEVELOPER_DIR

readonly XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
readonly BUILT_APP="$BUILD_ROOT/Build/Products/Release/$APP_NAME.app"

VERSION_INFO="$(/usr/bin/python3 - "$PBXPROJ_PATH" "${DAYDREAM_SKIP_BUMP:-0}" "${DAYDREAM_VERSION:-}" <<'PY'
import pathlib, re, sys

pbxproj = pathlib.Path(sys.argv[1])
skip_bump = sys.argv[2] == "1"
override_version = sys.argv[3].strip()
text = pbxproj.read_text()

version_match = re.search(r'MARKETING_VERSION = ([^;]+);', text)
build_match = re.search(r'CURRENT_PROJECT_VERSION = (\d+);', text)
if not version_match or not build_match:
    sys.exit("Error: Could not find MARKETING_VERSION or CURRENT_PROJECT_VERSION in project.pbxproj")

current_version = version_match.group(1).strip()
current_build = int(build_match.group(1))

if skip_bump:
    next_version = override_version or current_version
    next_build = current_build
else:
    if override_version:
        next_version = override_version
    else:
        parts = current_version.split(".")
        if len(parts) == 3 and all(p.isdigit() for p in parts):
            parts[2] = str(int(parts[2]) + 1)
            next_version = ".".join(parts)
        elif len(parts) == 2 and all(p.isdigit() for p in parts):
            next_version = f"{parts[0]}.{parts[1]}.1"
        else:
            next_version = current_version
    next_build = current_build + 1

print(f"{current_version} {current_build} {next_version} {next_build}")
PY
)"
read -r CURRENT_VERSION CURRENT_BUILD APP_VERSION APP_BUILD <<< "$VERSION_INFO"

if [[ "${DAYDREAM_SKIP_BUMP:-0}" != "1" ]]; then
    PBXPROJ_BACKUP="$BUILD_ROOT/project.pbxproj.bak"
    /bin/cp "$PBXPROJ_PATH" "$PBXPROJ_BACKUP"
    /usr/bin/python3 - "$PBXPROJ_PATH" "$APP_VERSION" "$APP_BUILD" <<'PY'
import pathlib, re, sys

pbxproj = pathlib.Path(sys.argv[1])
next_version = sys.argv[2]
next_build = sys.argv[3]
text = pbxproj.read_text()
text = re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {next_version};', text)
text = re.sub(r'CURRENT_PROJECT_VERSION = \d+;', f'CURRENT_PROJECT_VERSION = {next_build};', text)
pbxproj.write_text(text)
PY
    print -- "Bumped version: $CURRENT_VERSION ($CURRENT_BUILD) -> $APP_VERSION ($APP_BUILD)"
else
    print -- "Version: $APP_VERSION ($APP_BUILD) (bump skipped)"
fi

print -- "Using Xcode: ${DEVELOPER_DIR%/Contents/Developer}"
print -- "Building $APP_NAME $APP_VERSION ($APP_BUILD) in Release configuration..."

"$XCODEBUILD" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS,arch=$HOST_ARCHITECTURE" \
    -derivedDataPath "$BUILD_ROOT" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

if [[ ! -d "$BUILT_APP" ]]; then
    print -u2 -- "Error: Build succeeded but the application was not found at $BUILT_APP"
    exit 1
fi

print -- "Signing $APP_NAME with the shared local identity..."
/usr/bin/codesign \
    --force \
    --deep \
    --sign "$SIGNING_FINGERPRINT" \
    --identifier "$BUNDLE_IDENTIFIER" \
    "$BUILT_APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

DESIGNATED_REQUIREMENT="$(/usr/bin/codesign -d -r- "$BUILT_APP" 2>&1 | /usr/bin/sed -n '/^designated =>/p')"
if [[ -z "$DESIGNATED_REQUIREMENT" ]]; then
    print -u2 -- "Error: The signed build does not have a designated requirement."
    exit 1
fi
if [[ "$DESIGNATED_REQUIREMENT" == *"cdhash"* ]]; then
    print -u2 -- "Error: The build still has a cdhash-only designated requirement."
    print -u2 -- "Refusing to install an unstable code identity that would invalidate Accessibility permission."
    exit 1
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    print -- "Closing the running $APP_NAME application..."
    osascript -e "tell application id \"$BUNDLE_IDENTIFIER\" to quit" >/dev/null 2>&1 || true

    for _ in {1..20}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.25
    done

    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        print -u2 -- "Error: $APP_NAME is still running. Quit it manually and run this script again."
        exit 1
    fi
fi

print -- "Installing $APP_NAME to $INSTALL_PATH..."

if [[ -w "/Applications" && ( ! -e "$INSTALL_PATH" || -w "$INSTALL_PATH" ) ]]; then
    /usr/bin/ditto "$BUILT_APP" "$INSTALL_PATH"
else
    print -- "Administrator permission is required to write to /Applications."
    /usr/bin/sudo /usr/bin/ditto "$BUILT_APP" "$INSTALL_PATH"
fi

if [[ ! -x "$INSTALL_PATH/Contents/MacOS/$APP_NAME" ]]; then
    print -u2 -- "Error: Installation verification failed at $INSTALL_PATH"
    exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"; then
    print -u2 -- "Error: The installed application failed code-signature verification."
    exit 1
fi

INSTALLED_REQUIREMENT="$(/usr/bin/codesign -d -r- "$INSTALL_PATH" 2>&1 | /usr/bin/sed -n '/^designated =>/p')"
if [[ "$INSTALLED_REQUIREMENT" != "$DESIGNATED_REQUIREMENT" ]]; then
    print -u2 -- "Error: The installed application's designated requirement changed during installation."
    exit 1
fi

print -- "Opening $APP_NAME..."
/usr/bin/open "$INSTALL_PATH"

"$SCRIPT_DIR/verify-daydream-idle.command"
BUILD_COMPLETED=1

RELEASE_URL=""
if [[ "${DAYDREAM_SKIP_RELEASE:-0}" != "1" ]]; then
    if [[ -d "$SCRIPT_DIR/.git" && -d "$SCRIPT_DIR/.githooks" ]]; then
        /usr/bin/git -C "$SCRIPT_DIR" config core.hooksPath .githooks || true
    fi
    if GH_CLI="$(find_gh_cli)" && "$GH_CLI" auth status >/dev/null 2>&1; then
        if [[ -d "$SCRIPT_DIR/.git" ]] && ! /usr/bin/git -C "$SCRIPT_DIR" diff --quiet -- "daydream.xcodeproj/project.pbxproj"; then
            print -- "Committing version bump ($APP_VERSION build $APP_BUILD)..."
            /usr/bin/git -C "$SCRIPT_DIR" add -- "daydream.xcodeproj/project.pbxproj"
            /usr/bin/git -C "$SCRIPT_DIR" commit -m "Bump version to $APP_VERSION ($APP_BUILD)" -- "daydream.xcodeproj/project.pbxproj"
            CURRENT_BRANCH="$(/usr/bin/git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD)"
            DAYDREAM_RELEASE_IN_PROGRESS=1 /usr/bin/git -C "$SCRIPT_DIR" push origin "$CURRENT_BRANCH"
        fi

        RELEASE_TAG="v$APP_VERSION"
        if "$GH_CLI" release view "$RELEASE_TAG" --repo Fenc3s/daydream >/dev/null 2>&1; then
            RELEASE_TAG="v${APP_VERSION}-b${APP_BUILD}"
        fi

        RELEASE_ARCHIVE="$BUILD_ROOT/${APP_NAME}-${RELEASE_TAG}-${HOST_ARCHITECTURE}.zip"
        print -- "Packaging $APP_NAME for GitHub Release ($RELEASE_TAG)..."
        /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$INSTALL_PATH" "$RELEASE_ARCHIVE"

        print -- "Publishing GitHub Release $RELEASE_TAG..."
        RELEASE_URL="$("$GH_CLI" release create "$RELEASE_TAG" "$RELEASE_ARCHIVE" \
            --repo Fenc3s/daydream \
            --title "Daydream v$APP_VERSION (Build $APP_BUILD)" \
            --generate-notes)"
    else
        print -- "Skipping GitHub Release: gh CLI is not installed or not authenticated."
    fi
fi

print -- ""
print -- "Build and installation completed successfully."
print -- "Installed application: $INSTALL_PATH"
print -- "Version: $APP_VERSION ($APP_BUILD)"
print -- "Signing identity: $SIGNING_FINGERPRINT"
print -- "$INSTALLED_REQUIREMENT"
if [[ -n "$RELEASE_URL" ]]; then
    print -- "GitHub Release: $RELEASE_URL"
fi
