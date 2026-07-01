#!/bin/bash

# Build script for ClaudeUsageBar

echo "Building ClaudeUsageBar..."

# Create fresh build directory (delete any stale build to avoid accumulated xattrs
# from prior signs, which can cause "resource fork / detritus" errors on codesign).
rm -rf build
mkdir -p build

# Create app bundle structure first
APP_NAME="ClaudeUsageBar.app"
APP_PATH="build/$APP_NAME"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Info.plist
cp Info.plist "$APP_PATH/Contents/"

# Create icon if it doesn't exist
if [ ! -f "ClaudeUsageBar.icns" ]; then
    echo "Creating app icon..."
    ./make_app_icon.sh >/dev/null 2>&1
fi

# Copy icon to Resources
if [ -f "ClaudeUsageBar.icns" ]; then
    cp ClaudeUsageBar.icns "$APP_PATH/Contents/Resources/"
    # Update Info.plist to reference icon
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ClaudeUsageBar" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ClaudeUsageBar" "$APP_PATH/Contents/Info.plist"
fi

# Compile the Swift app for arm64
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    ClaudeUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -target arm64-apple-macos12.0

# Compile for x86_64 (Intel)
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64" \
    ClaudeUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -target x86_64-apple-macos12.0

# Create universal binary
lipo -create -output "$APP_PATH/Contents/MacOS/ClaudeUsageBar" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Clean up individual arch binaries
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64"
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Create PkgInfo file
echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Set proper permissions first
chmod 755 "$APP_PATH/Contents/MacOS/ClaudeUsageBar"

# Clean any "detritus" that codesign rejects: extended attributes, ._files, .DS_Store
xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete 2>/dev/null
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null
dot_clean "$APP_PATH" 2>/dev/null

# Sign with a Developer ID certificate when one is actually available, so
# the build stays notarizable. CODESIGN_IDENTITY lets you point at your own
# cert instead of the upstream maintainer's (you won't have theirs unless
# you are them). If neither is present in the keychain, fall back to ad-hoc
# signing so a local clone is still runnable — loudly, since that build
# can't be notarized and Gatekeeper will flag it on first launch. An
# EXPLICITLY requested CODESIGN_IDENTITY that fails still errors out loudly
# rather than silently falling back — that's a real config problem, not the
# expected "I don't have the upstream cert" gap this fallback exists for.
UPSTREAM_DEVELOPER_ID="Developer ID Application: Linkko Technology Pte Ltd (Q467HQ5432)"
DEVELOPER_ID="${CODESIGN_IDENTITY:-$UPSTREAM_DEVELOPER_ID}"
IDENTITY_OVERRIDDEN="${CODESIGN_IDENTITY:+1}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    if codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP_PATH"; then
        echo "✅ App signed with Developer ID"
        if codesign --verify --verbose=2 "$APP_PATH" 2>&1 | grep -q "valid on disk"; then
            echo "✅ Signature verified"
        else
            echo "❌ Signature verification failed — fix before shipping" >&2
            exit 1
        fi
    else
        echo "❌ Developer ID signing failed even though the identity is in your keychain." >&2
        echo "   Fix the cause above (often: stale xattrs / ._files) and re-run." >&2
        exit 1
    fi
elif [ -n "$IDENTITY_OVERRIDDEN" ]; then
    echo "❌ CODESIGN_IDENTITY=\"$DEVELOPER_ID\" is not in your keychain." >&2
    echo "   Run 'security find-identity -v -p codesigning' to see what's available." >&2
    exit 1
else
    echo "⚠️  \"$UPSTREAM_DEVELOPER_ID\" is not in your keychain — that's the upstream" >&2
    echo "   maintainer's cert, expected unless you are them." >&2
    echo "   Falling back to ad-hoc signing so the build is runnable locally." >&2
    echo "   This build is NOT notarizable; on first launch, right-click the app ->" >&2
    echo "   Open (instead of double-clicking) to get past Gatekeeper's warning." >&2
    echo "   To sign with your own Developer ID instead: set CODESIGN_IDENTITY to an" >&2
    echo "   identity from 'security find-identity -v -p codesigning' and re-run." >&2
    echo "   Note: ad-hoc signatures aren't stable across rebuilds, so each rebuild" >&2
    echo "   may trigger a one-time Keychain access prompt for the saved cookie." >&2
    echo "   If access is denied and re-pasting the cookie doesn't stick, clear the" >&2
    echo "   stale item first: security delete-generic-password -s com.claude.usagebar" >&2
    if codesign --force --deep --options runtime --sign - "$APP_PATH"; then
        echo "✅ App ad-hoc signed"
    else
        echo "❌ Even ad-hoc signing failed — something is wrong beyond a missing cert." >&2
        exit 1
    fi
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
echo "Launching app..."
open "$APP_PATH"
