#!/bin/bash
# Build Blink, sign it with the Developer ID and install it in /Applications/AI Apps.
#   ./build.sh            build + sign + install
#   NOTARIZE=1 ./build.sh also notarize and staple (needed only to share the app)
set -e
cd "$(dirname "$0")"

APP_NAME="Blink"
EXE="Blink"
BUNDLE_ID="com.decentespresso.blink"
VERSION="1.2.0"
DEST="${BLINK_DEST:-$( [ -d "/Applications/AI Apps" ] && echo "/Applications/AI Apps" || echo /Applications )}"
# The first Developer ID in the keychain (or set BLINK_IDENTITY); ad-hoc signing if there is none.
IDENTITY="${BLINK_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
NOTARY_PROFILE="${BLINK_NOTARY_PROFILE:-}"   # a `notarytool store-credentials` profile name

echo "== Building =="
swift build -c release --arch arm64
BIN=".build/arm64-apple-macosx/release/$EXE"
[ -f "$BIN" ] || BIN=".build/release/$EXE"

APP="$APP_NAME.app"
echo "== Assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp "$(dirname "$BIN")/libBlinkViewers.dylib" "$APP/Contents/Frameworks/"
strip -x "$APP/Contents/MacOS/$EXE" "$APP/Contents/Frameworks/libBlinkViewers.dylib"
cp Resources/Blink.icns "$APP/Contents/Resources/"

doctype() {  # name, then UTIs
    local name="$1"; shift
    echo "<dict><key>CFBundleTypeName</key><string>$name</string>"
    echo "<key>CFBundleTypeRole</key><string>Viewer</string>"
    echo "<key>LSHandlerRank</key><string>Alternate</string>"
    echo "<key>LSItemContentTypes</key><array>"
    for t in "$@"; do echo "<string>$t</string>"; done
    echo "</array></dict>"
}

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key>        <string>$EXE</string>
    <key>CFBundleIconFile</key>          <string>Blink</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSHumanReadableCopyright</key>  <string>GPL-3.0 · github.com/johnbuckman/blink</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        $(doctype Image public.image)
        $(doctype PDF com.adobe.pdf)
        $(doctype CSV public.comma-separated-values-text public.tab-separated-values-text)
        $(doctype Email com.apple.mail.email com.apple.mail.emlx)
        $(doctype Spreadsheet org.openxmlformats.spreadsheetml.sheet com.microsoft.excel.xls)
        $(doctype GPX com.topografix.gpx com.apple.dt.document.gpx)
        $(doctype Movie public.movie)
        $(doctype Audio public.audio)
        $(doctype Markdown net.daringfireball.markdown)
        $(doctype Text public.plain-text)
        $(doctype Word public.rtf com.microsoft.word.doc org.openxmlformats.wordprocessingml.document)
        $(doctype Source com.netscape.javascript-source org.tcl.tcl-source com.aolserver.adp)
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.topografix.gpx</string>
            <key>UTTypeDescription</key><string>GPS Exchange file</string>
            <key>UTTypeConformsTo</key><array><string>public.xml</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>gpx</string></array></dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key><string>Markdown document</string>
            <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>md</string><string>markdown</string></array></dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>org.tcl.tcl-source</string>
            <key>UTTypeDescription</key><string>Tcl script</string>
            <key>UTTypeConformsTo</key><array><string>public.script</string><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>tcl</string></array></dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.aolserver.adp</string>
            <key>UTTypeDescription</key><string>AOLserver dynamic page</string>
            <key>UTTypeConformsTo</key><array><string>public.source-code</string><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>adp</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "== Signing =="
codesign --force --options runtime --timestamp=$( [ "$IDENTITY" = - ] && echo none || echo http://timestamp.apple.com/ts01 ) --sign "$IDENTITY" "$APP/Contents/Frameworks/libBlinkViewers.dylib"
codesign --force --options runtime --timestamp=$( [ "$IDENTITY" = - ] && echo none || echo http://timestamp.apple.com/ts01 ) --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

if [ -n "$NOTARIZE" ]; then
    [ -n "$NOTARY_PROFILE" ] || { echo "set BLINK_NOTARY_PROFILE"; exit 1; }
    echo "== Notarizing =="
    ditto -c -k --keepParent "$APP" Blink.zip
    xcrun notarytool submit Blink.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm Blink.zip
    # The download: the stapled app, zipped for a GitHub release.
    ditto -c -k --keepParent "$APP" "Blink-$VERSION.zip"
    echo "Release zip: Blink-$VERSION.zip"
fi

echo "== Installing to $DEST =="
mkdir -p "$DEST"
pkill -x "$EXE" 2>/dev/null || true
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP"
echo "Done: $DEST/$APP"
