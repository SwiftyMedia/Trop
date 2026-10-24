#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
WORKING_LOCATION="$(pwd)"

# FFmpegKit and MPVKit both ship ffmpeg libraries whose framework names differ
# only by case (Libavcodec.framework vs libavcodec.framework). The iOS installer
# (and isideload's re-signing pipeline, which extracts the IPA onto a
# case-INSENSITIVE Mac volume) merges those two folders, corrupting the FFmpegKit
# framework and producing "missing its bundle executable" at install time
#
# Fix: rename FFmpegKit's 7 colliding frameworks to an `fk_` prefix so they stay
# distinct from MPVKit's `Lib*` frameworks even on a case-insensitive filesystem.
# This renames the xcframework folder, the inner framework, the binary, the
# Info.plist CFBundleExecutable, and every cross install-name reference
rename_ffmpegkit_frameworks() {
    local xcf="$FFMPEG_KIT_XCF"
    local prefix="fk_"
    local libs=(libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale)
    for l in "${libs[@]}"; do
        local new="${prefix}${l}"
        local xc="$xcf/$l.xcframework"
        [ -d "$xc" ] || continue
        mv "$xc" "$xcf/$new.xcframework"
        local xcnew="$xcf/$new.xcframework"
        # Keep the xcframework manifest in sync with the renamed inner framework
        # Note: $new.framework contains $l.framework as a substring, so we must
        # patch LibraryPath (.../l.framework) before BinaryPath (.../l.framework/l)
        # and use a trailing-slash pattern for the binary name to avoid re-matching
        local xpl="$xcnew/Info.plist"
        if [ -f "$xpl" ]; then
            sed -i '' -e "s#$l\.framework#$new.framework#g" -e "s#/$l#/$new#g" "$xpl"
        fi
        find "$xcnew" -type d -name "$l.framework" | while read -r fw; do
            local parent
            parent="$(dirname "$fw")"
            mv "$fw" "$parent/$new.framework"
            local bin="$parent/$new.framework/$l"
            [ -f "$bin" ] || continue
            mv "$bin" "$parent/$new.framework/$new"
            local newbin="$parent/$new.framework/$new"
            /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $new" "$parent/$new.framework/Info.plist" 2>/dev/null || true
            chmod +w "$newbin"
            install_name_tool -id "@rpath/$new.framework/$new" "$newbin" 2>/dev/null || true
        done
    done
    # Rewrite cross-references across every ffmpeg-kit Mach-O binary
    local allbins=()
    while IFS= read -r -d '' b; do allbins+=("$b"); done < <(find "$xcf" -type f -path "*.framework/*" \( -name "fk_*" -o -name "ffmpegkit" \) -print0)
    for old in "${libs[@]}"; do
        local new="${prefix}${old}"
        local oldpath="@rpath/$old.framework/$old"
        local newpath="@rpath/$new.framework/$new"
        for b in "${allbins[@]}"; do
            if file "$b" 2>/dev/null | grep -q "Mach-O"; then
                chmod +w "$b"
                install_name_tool -change "$oldpath" "$newpath" "$b" 2>/dev/null || true
            fi
        done
    done
    echo "Renamed ffmpeg-kit frameworks with '${prefix}' prefix."
}
# Remove any stray extra Mach-O binary inside a framework (e.g. a leftover
# capitalized duplicate such as Ffmpegkit next to ffmpegkit). iOS/isideload expect
# exactly one executable per framework matching CFBundleExecutable
sanitize_framework_binaries() {
    local app="$1"
    local fwdir="$app/Frameworks"
    [ -d "$fwdir" ] || return 0
    for fw in "$fwdir"/*.framework; do
        [ -d "$fw" ] || continue
        local exe
        exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$fw/Info.plist" 2>/dev/null)"
        [ -n "$exe" ] || continue
        for f in "$fw"/*; do
            [ -f "$f" ] || continue
            [ "$(basename "$f")" = "$exe" ] && continue
            if file "$f" 2>/dev/null | grep -q "Mach-O"; then
                echo "Removing stray binary $(basename "$f") from $(basename "$fw")"
                rm -f "$f"
            fi
        done
    done
}

# Adds or updates a string key in a plist (never fails the build).
inject_plist_string() {
    local key="$1" value="$2" plist="$3"
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :$key string $value" "$plist" 2>/dev/null || true
}

APPLICATION_NAME=Trop
PROJECT_NAME=Trop
# MPVKit and FFmpegKit both ship ffmpeg libraries whose framework names differ
# only by case (Libavcodec.framework vs libavcodec.framework). On the default
# case-INSENSITIVE macOS volume those collapse into one directory and the wrong
# binary wins the merge, breaking the link. Build derived data on a case-SENSITIVE
# volume so the two framework sets stay distinct
CASE_SENSITIVE_VOL="$HOME/Library/Caches/TropBuild.sparseimage"
CASE_SENSITIVE_MOUNT="/Volumes/TropBuild"
if [ ! -f "$CASE_SENSITIVE_VOL" ]; then
    echo "Creating case-sensitive build volume at $CASE_SENSITIVE_VOL..."
    hdiutil create -size 20g -type SPARSE -fs 'Case-sensitive APFS' -volname TropBuild "$CASE_SENSITIVE_VOL"
fi
if ! mount | grep -q " $CASE_SENSITIVE_MOUNT "; then
    hdiutil attach "$CASE_SENSITIVE_VOL" -mountpoint "$CASE_SENSITIVE_MOUNT" -nobrowse >/dev/null 2>&1 \
        || { echo "ERROR: failed to mount case-sensitive build volume"; exit 1; }
fi

BUILD_DIR="$WORKING_LOCATION/build"
DERIVED_DATA_PATH="$CASE_SENSITIVE_MOUNT/DerivedDataApp"
# Assemble the .app and IPA on the case-sensitive volume so the distinct
# libavcodec.framework (FFmpegKit) and Libavcodec.framework (MPVKit) directories
# never collapse into one, and so the capitalized installer copies stay separate
STAGE_DIR="$CASE_SENSITIVE_MOUNT/stage"
OUTPUT_APP_PATH="$STAGE_DIR/$APPLICATION_NAME.app"
PAYLOAD_DIR="$STAGE_DIR/Payload"
IPA_PATH="$BUILD_DIR/$APPLICATION_NAME.ipa"
FFMPEG_KIT_DIR="$BUILD_DIR/ffmpeg-kit-next"
FFMPEG_KIT_XCF="$BUILD_DIR/ffmpeg-kit-xcframeworks"
# v8.1.x tags are Nix-only (no ios.sh). v9.0.0+ ships the classic ios.sh entrypoint.
FFMPEG_KIT_TAG="${FFMPEG_KIT_TAG:-v9.0.0}"

mkdir -p "$BUILD_DIR"
mkdir -p "$STAGE_DIR"

if [ ! -d "$FFMPEG_KIT_XCF" ]; then
    echo "Building ffmpeg-kit-next ($FFMPEG_KIT_TAG)..."
    if [ ! -d "$FFMPEG_KIT_DIR" ]; then
        echo "    Cloning ffmpeg-kit-next..."
        git clone --depth 1 --branch "$FFMPEG_KIT_TAG" \
            https://github.com/arthenica/ffmpeg-kit-next.git "$FFMPEG_KIT_DIR"
    fi
    cd "$FFMPEG_KIT_DIR"
    if [ ! -f ./ios.sh ]; then
        echo "    ERROR: ios.sh missing in ffmpeg-kit-next @$FFMPEG_KIT_TAG"
        echo "    Use a tag that includes the classic build scripts (v9.0.0+), or nix-ios.sh."
        exit 1
    fi
    if ! command -v gsed >/dev/null 2>&1; then
        echo "    Installing build dependencies..."
        brew install gnu-sed pkg-config autoconf automake libtool
    fi
    # One -x invocation builds device + simulator into a single XCFramework.
    # Separate ios.sh runs recreate the output directory and drop the earlier
    # slice, which breaks device IPA linking. Disable unused default arches.
    echo "Building arm64 device + simulator XCFrameworks..."
    SED=gsed ./ios.sh -x --spm --enable-lib-openssl \
        --disable-arch-arm64e \
        --disable-arch-arm64-mac-catalyst \
        --disable-arch-x86-64 \
        --disable-arch-x86-64-mac-catalyst \
        || { echo "    FAILED: ffmpeg-kit XCFramework build"; exit 1; }
    echo "Copying xcframeworks..."
    cp -R "$FFMPEG_KIT_DIR/prebuilt/bundle-apple-xcframework-ios-12.1" "$FFMPEG_KIT_XCF"
    echo "ffmpeg-kit-next build complete."
    cd "$WORKING_LOCATION"
fi

# Safety net: if the renamed ffmpeg-kit framework binary is missing, restore the
# pristine prebuilt bundle (lowercase) without rebuilding
if [ ! -f "$FFMPEG_KIT_XCF/fk_libavcodec.xcframework/ios-arm64/fk_libavcodec.framework/fk_libavcodec" ] \
   && [ -d "$FFMPEG_KIT_DIR/prebuilt/bundle-apple-xcframework-ios-12.1" ]; then
    echo "Restoring pristine ffmpeg-kit xcframeworks from prebuilt..."
    rm -rf "$FFMPEG_KIT_XCF"
    cp -R "$FFMPEG_KIT_DIR/prebuilt/bundle-apple-xcframework-ios-12.1" "$FFMPEG_KIT_XCF"
fi

# Rename FFmpegKit frameworks away from MPVKit's case-only-different names
# Idempotent: only runs while the pristine lowercase xcframeworks are present
if [ -d "$FFMPEG_KIT_XCF/libavcodec.xcframework" ]; then
    rename_ffmpegkit_frameworks
fi

# Update the Xcode project references to the renamed xcframeworks. Runs only
# while the project still references the pristine lowercase names; once renamed
# (fk_*), the guard prevents a re-run from double-prefixing
local_pbx="$WORKING_LOCATION/$PROJECT_NAME.xcodeproj/project.pbxproj"
if ! grep -q "fk_libavcodec.xcframework" "$local_pbx"; then
    echo "Updating project references to renamed ffmpeg-kit xcframeworks..."
    sed -i '' \
        -e 's/libavcodec\.xcframework/fk_libavcodec.xcframework/g' \
        -e 's/libavdevice\.xcframework/fk_libavdevice.xcframework/g' \
        -e 's/libavfilter\.xcframework/fk_libavfilter.xcframework/g' \
        -e 's/libavformat\.xcframework/fk_libavformat.xcframework/g' \
        -e 's/libavutil\.xcframework/fk_libavutil.xcframework/g' \
        -e 's/libswresample\.xcframework/fk_libswresample.xcframework/g' \
        -e 's/libswscale\.xcframework/fk_libswscale.xcframework/g' \
        "$local_pbx"
fi

cd "$BUILD_DIR"

XCODEBUILD_ACTION="${XCODEBUILD_ACTION:-build}"
if [ "${CLEAN_BUILD:-0}" = "1" ]; then
    XCODEBUILD_ACTION="clean build"
fi

# Inject Last.fm secrets from the local scheme or GitHub Actions secrets.
# Scheme variables are used for local builds; workflow environment variables
# take precedence when the build runs in GitHub Actions.
SCHEME_PATH="$WORKING_LOCATION/Trop.xcodeproj/xcshareddata/xcschemes/$APPLICATION_NAME.xcscheme"
scheme_environment_value() {
    local wanted_key="$1"
    [ -f "$SCHEME_PATH" ] || return 0
    awk -v wanted_key="$wanted_key" '
        /<EnvironmentVariable/ { in_variable = 1; key = ""; value = "" }
        in_variable && /key = "/ {
            line = $0
            sub(/^.*key = "/, "", line)
            sub(/".*$/, "", line)
            key = line
        }
        in_variable && /value = "/ {
            line = $0
            sub(/^.*value = "/, "", line)
            sub(/".*$/, "", line)
            value = line
        }
        in_variable && /<\/EnvironmentVariable>/ {
            if (key == wanted_key) print value
            in_variable = 0
        }
    ' "$SCHEME_PATH" | head -n 1
}

LASTFM_API_KEY_SOURCE="${LASTFM_API_KEY:-}"
LASTFM_SECRET_SOURCE="${LASTFM_SECRET:-}"
if [ -z "$LASTFM_API_KEY_SOURCE" ]; then
    LASTFM_API_KEY_SOURCE="$(scheme_environment_value LASTFM_API_KEY)"
fi
if [ -z "$LASTFM_SECRET_SOURCE" ]; then
    LASTFM_SECRET_SOURCE="$(scheme_environment_value LASTFM_SECRET)"
fi

# Trim whitespace/newlines (secrets pasted with newline cause Last.fm error 6).
LASTFM_API_KEY_TRIMMED="$(echo "$LASTFM_API_KEY_SOURCE" | tr -d '\r\n' | xargs 2>/dev/null || echo "$LASTFM_API_KEY_SOURCE")"
LASTFM_SECRET_TRIMMED="$(echo "$LASTFM_SECRET_SOURCE" | tr -d '\r\n' | xargs 2>/dev/null || echo "$LASTFM_SECRET_SOURCE")"

if [ "${GITHUB_ACTIONS:-}" = "true" ] || [ -n "$LASTFM_API_KEY_TRIMMED" ] || [ -n "$LASTFM_SECRET_TRIMMED" ]; then

    if [ -n "$LASTFM_API_KEY_TRIMMED" ]; then
        echo "Injecting LASTFM_API_KEY (len=${#LASTFM_API_KEY_TRIMMED})"
        inject_plist_string "LASTFM_API_KEY" "$LASTFM_API_KEY_TRIMMED" "$WORKING_LOCATION/Trop/Resources/Info.plist"
    else
        echo "Warning: LASTFM_API_KEY empty - Last.fm login will fail with error 6"
    fi
    if [ -n "$LASTFM_SECRET_TRIMMED" ]; then
        echo "Injecting LASTFM_SECRET (len=${#LASTFM_SECRET_TRIMMED})"
        inject_plist_string "LASTFM_SECRET" "$LASTFM_SECRET_TRIMMED" "$WORKING_LOCATION/Trop/Resources/Info.plist"
    else
        echo "Warning: LASTFM_SECRET empty - Last.fm login will fail with error 6"
    fi
    XCODE_LASTFM_ARGS=()
    if [ -n "$LASTFM_API_KEY_TRIMMED" ]; then
        XCODE_LASTFM_ARGS+=("INFOPLIST_KEY_LASTFM_API_KEY=$LASTFM_API_KEY_TRIMMED")
    fi
    if [ -n "$LASTFM_SECRET_TRIMMED" ]; then
        XCODE_LASTFM_ARGS+=("INFOPLIST_KEY_LASTFM_SECRET=$LASTFM_SECRET_TRIMMED")
    fi

else
    echo "Last.fm credentials not found in environment or scheme - skipping credential injection."
fi

# CI sets CURRENT_PROJECT_VERSION to the run number
# so AltStore/Feather can detect nightly updates while marketing version stays put.
XCODE_VERSION_ARGS=()
if [ -n "${CURRENT_PROJECT_VERSION:-}" ]; then
    XCODE_VERSION_ARGS+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")
fi
if [ -n "${MARKETING_VERSION:-}" ]; then
    XCODE_VERSION_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION")
fi

# shellcheck disable=SC2086
# Empty arrays + `set -u` explode on macOS bash 3.2; expand only when populated.
xcodebuild -project "$WORKING_LOCATION/$PROJECT_NAME.xcodeproj" \
    -scheme "$APPLICATION_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination 'generic/platform=iOS' \
    $XCODEBUILD_ACTION \
    SKIP_SWIFTLINT=YES \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO" \
    ${XCODE_LASTFM_ARGS[@]+"${XCODE_LASTFM_ARGS[@]}"} \
    ${XCODE_VERSION_ARGS[@]+"${XCODE_VERSION_ARGS[@]}"}

DD_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release-iphoneos/$APPLICATION_NAME.app"

if [ ! -d "$DD_APP_PATH" ]; then
    echo "Error: built app not found at $DD_APP_PATH"
    exit 1
fi

rm -rf "$OUTPUT_APP_PATH"
cp -r "$DD_APP_PATH" "$OUTPUT_APP_PATH"

# Strip any leftover duplicate/extra Mach-O binaries from embedded frameworks
sanitize_framework_binaries "$OUTPUT_APP_PATH"

codesign --remove "$OUTPUT_APP_PATH" || true
rm -rf "$OUTPUT_APP_PATH/_CodeSignature"
rm -rf "$OUTPUT_APP_PATH/embedded.mobileprovision"

rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
cp -r "$OUTPUT_APP_PATH" "$PAYLOAD_DIR/$APPLICATION_NAME.app"

if [ -f "$PAYLOAD_DIR/$APPLICATION_NAME.app/$APPLICATION_NAME" ]; then
    strip "$PAYLOAD_DIR/$APPLICATION_NAME.app/$APPLICATION_NAME"
fi

cd "$STAGE_DIR"
rm -f "$IPA_PATH"
zip -vr "$IPA_PATH" "Payload"

rm -rf "$PAYLOAD_DIR"

echo "IPA created at $IPA_PATH"
