#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Buddy.app
pkill -x Buddy 2>/dev/null || true
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp .build/release/Buddy $APP/Contents/MacOS/Buddy
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.buddy</string>
<key>CFBundleName</key><string>Buddy</string>
<key>CFBundleExecutable</key><string>Buddy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Buddy listens to your voice commands.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Buddy turns your speech into text.</string>
<key>NSAppleEventsUsageDescription</key><string>Buddy automates apps like Finder for you.</string>
</dict></plist>
PL
codesign --force --deep -s - $APP
open $APP
