# EcoPin Backend Dockerfile
# Multi-stage build for optimal image size and security

# Stage 1: Base image with system dependencies
FROM node:20-alpine AS base

# Install ffmpeg and system dependencies
RUN apk add --no-cache \
    ffmpeg \
    ffmpeg-dev \
    imagemagick \
    python3 \
    py3-pip \
    make \
    g++ \
    cairo-dev \
    jpeg-dev \
    pango-dev \
    musl-dev \
    giflib-dev \
    pkgconfig

# Verify ffmpeg installation
RUN ffmpeg -version

# Set working directory
WORKDIR /app

# Stage 2: Dependencies
FROM base AS dependencies

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --only=production && \
    npm cache clean --force

# Stage 3: Development build (optional)
FROM dependencies AS development

# Install all dependencies (including dev)
RUN npm install

# Copy source code
COPY . .

# Stage 4: Production build
FROM dependencies AS production

# Copy source code
COPY . .

# Create non-root user for security
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001

# Change ownership of app directory
RUN chown -R nodejs:nodejs /app

# Switch to non-root user
USER nodejs

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Start application
CMD ["node", "src/index.js"]