#!/bin/bash

# Parse arguments
DEBUG_MODE=false
for arg in "$@"; do
    if [[ "$arg" == "-d" ]] || [[ "$arg" == "--debug" ]]; then
        DEBUG_MODE=true
        break
    fi
done

# Kill existing processes
killall -9 Clippy 2>/dev/null

# Check and start AI Servers
echo "🔍 Checking AI Servers..."
SERVERS_RUNNING=true

# Check Vision (8081)
if ! lsof -i :8081 -sTCP:LISTEN -t >/dev/null; then SERVERS_RUNNING=false; fi
# Check RAG (8082)
if ! lsof -i :8082 -sTCP:LISTEN -t >/dev/null; then SERVERS_RUNNING=false; fi
# Check Extract (8083)
if ! lsof -i :8083 -sTCP:LISTEN -t >/dev/null; then SERVERS_RUNNING=false; fi

if [ "$SERVERS_RUNNING" = false ]; then
    echo "⚠️  Some servers are not running. Starting them..."
    ./test/start_all_servers.sh
    # Wait a bit for servers to initialize
    sleep 3
else
    echo "✅ All AI servers are running."
fi

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
EXECUTABLE_NAME=$(echo "$BUILD_SETTINGS" | grep " EXECUTABLE_NAME =" | cut -d "=" -f 2 | xargs)

if [ -d "$APP_PATH" ]; then
    if [ "$DEBUG_MODE" = true ]; then
        echo "✅ App started at $APP_PATH (Debug Mode)"
        "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
    else
        open "$APP_PATH"
        echo "✅ App started at $APP_PATH"
    fi
else
    echo "❌ App not found at $APP_PATH"
    exit 1
fi

pgrep -fl Clippy
