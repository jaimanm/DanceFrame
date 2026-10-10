#!/bin/bash
set -e

# package_app.sh: Packages DanceFrame into a native DanceFrame.app macOS bundle

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "==> Building DanceFrame (release configuration)..."
DEVELOPER_DIR=/Library/Developer/CommandLineTools /Library/Developer/CommandLineTools/usr/bin/swift build -c release

APP_DIR="$DIR/DanceFrame.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Creating macOS Application Bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary
cp "$DIR/.build/release/DanceFrame" "$MACOS_DIR/DanceFrame"
chmod +x "$MACOS_DIR/DanceFrame"

# Bundle embedded FFmpeg if present
if [ -d "$DIR/build-resources/binaries" ]; then
    echo "==> Bundling embedded FFmpeg binaries into App Resources..."
    cp -R "$DIR/build-resources/binaries" "$RESOURCES_DIR/binaries"
fi

# Create Info.plist
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DanceFrame</string>
    <key>CFBundleIdentifier</key>
    <string>com.danceframe.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DanceFrame</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Successfully packaged DanceFrame.app!"
echo "You can open it via: open DanceFrame.app"
