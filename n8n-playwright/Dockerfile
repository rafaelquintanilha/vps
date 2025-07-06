FROM n8nio/n8n:latest

USER root

# Install Chromium and all required dependencies for Alpine
RUN apk update && apk add --no-cache \
    chromium \
    chromium-chromedriver \
    nss \
    freetype \
    freetype-dev \
    harfbuzz \
    ca-certificates \
    ttf-freefont \
    dbus \
    dbus-x11 \
    eudev \
    ttf-liberation \
    font-noto-emoji \
    # Fixed package names for Alpine
    libxcomposite \
    libxdamage \
    libxrandr \
    libxscrnsaver \
    libxtst \
    at-spi2-core \
    cups-libs \
    libdrm \
    libxkbcommon \
    mesa-gbm \
    alsa-lib \
    pango \
    # Additional useful packages
    nodejs \
    npm \
    # Python for any additional scripts
    python3 \
    py3-pip

# Create necessary directories and set permissions
RUN mkdir -p /tmp/.X11-unix && \
    chmod 1777 /tmp/.X11-unix && \
    mkdir -p /home/node/.cache && \
    chown -R node:node /home/node

# Set environment variables for Chromium
ENV CHROME_BIN=/usr/bin/chromium-browser \
    CHROME_PATH=/usr/lib/chromium/ \
    CHROMIUM_FLAGS="--disable-software-rasterizer --disable-dev-shm-usage"

# Switch back to node user
USER node

# Install Puppeteer without downloading Chrome (we'll use system Chrome)
RUN cd /home/node && \
    npm init -y && \
    npm install puppeteer-core playwright-core

# Make the modules available globally
ENV NODE_PATH=/home/node/node_modules

WORKDIR /home/node/.n8n