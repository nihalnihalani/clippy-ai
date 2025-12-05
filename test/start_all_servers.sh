#!/bin/bash

# Start all LFM2 servers
echo "🚀 Starting all LFM2 Servers..."

# Vision (8081)
echo "👁️  Starting Vision Server (8081)..."
./test/vision/run_vision.sh > test/vision/vision.log 2>&1 &

# RAG (8082)
echo "🤖 Starting RAG Server (8082)..."
./test/rag/run_rag.sh > test/rag/rag.log 2>&1 &

# Extract (8083)
echo "⛏️  Starting Extract Server (8083)..."
./test/extract/run_extract.sh > test/extract/extract.log 2>&1 &

echo "✅ All servers started in background!"
echo "   - Vision: http://localhost:8081"
echo "   - RAG:    http://localhost:8082"
echo "   - Extract: http://localhost:8083"
echo "Logs are in test/vision/, test/rag/, and test/extract/"
