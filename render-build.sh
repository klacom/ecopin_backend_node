#!/bin/bash
# EcoPin Backend Render Build Script
# This script installs dependencies and prepares the application for deployment on Render

set -e  # Exit on error

echo "🚀 Starting EcoPin Backend build process..."

# Install ffmpeg for video processing
echo "📦 Installing ffmpeg for video processing..."
apt-get update && apt-get install -y ffmpeg

# Verify ffmpeg installation
echo "🔍 Verifying ffmpeg installation..."
if command -v ffmpeg &> /dev/null; then
    echo "✅ ffmpeg installed successfully:"
    ffmpeg -version | head -n 1
else
    echo "❌ ffmpeg installation failed"
    exit 1
fi

# Install Node.js dependencies
echo "📦 Installing Node.js dependencies..."
npm ci --production

# Run database migrations if migration files exist
if [ -d "migrations" ]; then
    echo "🗄️  Running database migrations..."
    # Add migration command here when migrations are set up
    # Example: npx supabase db push
fi

# Create necessary directories
echo "📁 Creating necessary directories..."
mkdir -p logs
mkdir -p tmp

# Set environment variables
export NODE_ENV=${NODE_ENV:-production}
export PORT=${PORT:-3000}

echo "✅ Build process completed successfully!"
echo "🎯 Starting application on port ${PORT}..."