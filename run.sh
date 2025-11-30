#!/bin/bash

# Kill existing processes
killall -9 Clippy 2>/dev/null

# Build
xcodebuild -project Clippy.xcodeproj \
           -scheme Clippy \
           -destination 'platform=macOS,arch=arm64' \
           -configuration Debug \
           CODE_SIGN_IDENTITY="" \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGNING_ALLOWED=NO

if [ $? -ne 0 ]; then
    echo "❌ Build failed"
    exit 1
fi

# Run
BUILD_SETTINGS=$(xcodebuild -project Clippy.xcodeproj -scheme Clippy -showBuildSettings -configuration Debug 2>/dev/null)
TARGET_BUILD_DIR=$(echo "$BUILD_SETTINGS" | grep " TARGET_BUILD_DIR =" | cut -d "=" -f 2 | xargs)
FULL_PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | grep " FULL_PRODUCT_NAME =" | cut -d "=" -f 2 | xargs)
APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

if [ -d "$APP_PATH" ]; then
    open "$APP_PATH"
    echo "✅ App started at $APP_PATH"
else
    echo "❌ App not found at $APP_PATH"
    exit 1
fi

pgrep -fl Clippy
