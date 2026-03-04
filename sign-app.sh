APP="/Users/herbert/web/bulwark-video-tool/dist/In-Out.app"
IDENTITY="Developer ID Application: Center Enterprises, Inc. (4PRCD73FWP)"

codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"
