#!/bin/bash
# Kiritori をビルドして build/Kiritori.app と配布用 zip を作る。
# Xcode は不要。Command Line Tools の swiftc だけで通る。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Kiritori"
# 2026-11-21 に local.kiritori から付け直した（理由は「Mac miniでの入れ方.md」の「作り直すとき」）
BUNDLE_ID="${KIRITORI_BUNDLE_ID:-local.takesuzue.kiritori}"
VERSION="${KIRITORI_VERSION:-0.20.0}"
MIN_OS="13.0"
# 試作は KIRITORI_BUILD_DIR=build-dev KIRITORI_BUNDLE_ID=local.takesuzue.kiritori.dev ./build.sh で別の場所に作る
# （動いている本体を止めずに済み、画面収録の許可も外れない）
BUILD="${KIRITORI_BUILD_DIR:-build}"
APP="$BUILD/$APP_NAME.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Apple シリコンと Intel の両方で動くようにする
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_OS" Sources/*.swift -o "$BUILD/$APP_NAME-$arch"
done
lipo -create "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
rm "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"

cp Resources/Kiritori.icns "$APP/Contents/Resources/Kiritori.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>Kiritori</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>録画にマイクの音を入れるために使います。</string>
  <key>NSCameraUsageDescription</key><string>録画にカメラの映像を重ねるために使います。</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 署名に「識別名で見分ける」指定を付ける。付けないと作り直すたびに別アプリ扱いになり、画面収録の許可が外れる。
codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
# 更新日時を進めておく（同じ場所に作り直すと Finder が古いアイコンを出し続けるため）
touch "$APP"
ditto -c -k --keepParent "$APP" "$BUILD/$APP_NAME-$VERSION.zip"

echo "できたもの:"
echo "  $APP"
echo "  $BUILD/$APP_NAME-$VERSION.zip"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
