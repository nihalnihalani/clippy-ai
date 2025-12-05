#!/bin/bash

# Run LFM2-1.2B-Extract server
# Port: 8083

echo "🚀 Starting LFM2-1.2B-Extract Server (Native MLX)..."
echo "📱 Model: LiquidAI/LFM2-1.2B-Extract"
echo "🔌 Port: 8083"

# Use mlx_lm.server for text models
python -m mlx_lm.server --model LiquidAI/LFM2-1.2B-Extract --port 8083
