#!/bin/bash

# Run LFM2-1.2B-RAG server
# Port: 8082

echo "🚀 Starting LFM2-1.2B-RAG Server (Native MLX)..."
echo "📱 Model: mlx-community/LFM2-1.2B-RAG"
echo "🔌 Port: 8082"

# Use mlx_lm.server for text models
python -m mlx_lm.server --model LiquidAI/LFM2-1.2B-RAG --port 8082
