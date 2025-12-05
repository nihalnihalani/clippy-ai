#!/bin/bash
# Run the LFM2-VL-3B vision model server natively on macOS
# Port 8081 to avoid conflict with text model on 8080

echo "🚀 Starting LFM2-VL-3B Vision Server (Native MLX)..."
echo "📱 Model: mlx-community/LFM2-VL-3B-4bit"
echo "🔌 Port: 8081"

python "$(dirname "$0")/custom_vision_server.py" --port 8081
