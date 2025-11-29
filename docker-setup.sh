#!/bin/bash

# MPD Web Control - Docker Installation Script
# Sets up containerized MPD + Maestro web interface

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}ℹ️ $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️ $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Function to detect and configure audio system
configure_audio_system() {
    log_info "Detecting available audio devices..."
    
    # Check for PulseAudio
    PULSE_AVAILABLE=false
    if command -v pulseaudio >/dev/null 2>&1 && pulseaudio --check; then
        PULSE_AVAILABLE=true
        log_success "PulseAudio detected and running"
    fi
    
    # Check for ALSA
    ALSA_AVAILABLE=false
    if [ -e /dev/snd/controlC0 ]; then
        ALSA_AVAILABLE=true
        log_success "ALSA audio devices detected"
    fi
    
    if [ "$PULSE_AVAILABLE" = false ] && [ "$ALSA_AVAILABLE" = false ]; then
        log_warning "No audio system detected"
        echo "   Audio playback may not work properly"
        return
    fi
    
    # Get current user for audio group access
    CURRENT_USER=$(whoami)
    USER_ID=$(id -u)
    
    # Check if user is in audio group
    if ! groups "$CURRENT_USER" | grep -q audio; then
        log_warning "User $CURRENT_USER is not in 'audio' group"
        echo "   Adding user to audio group for sound card access..."
        sudo usermod -aG audio "$CURRENT_USER"
        log_success "User added to audio group (may require logout/login)"
    fi
    
    # List available audio devices
    echo
    log_info "Available audio devices:"
    
    if [ "$PULSE_AVAILABLE" = true ]; then
        echo "📢 PulseAudio Devices:"
        pactl list short sinks | while read -r line; do
            sink_id=$(echo "$line" | cut -f1)
            sink_name=$(echo "$line" | cut -f2)
            echo "   • $sink_name"
        done
        AUDIO_SYSTEM="pulse"
        PULSE_SOCKET_PATH="/run/user/$USER_ID/pulse"
    fi
    
    if [ "$ALSA_AVAILABLE" = true ]; then
        echo "🔊 ALSA Devices:"
        if command -v aplay >/dev/null 2>&1; then
            aplay -l 2>/dev/null | grep "card\|device" | head -5
        else
            ls /dev/snd/controlC* 2>/dev/null | while read -r device; do
                card_num=$(echo "$device" | grep -o '[0-9]*$')
                echo "   • Card $card_num: /dev/snd/controlC$card_num"
            done
        fi
        if [ "$PULSE_AVAILABLE" = false ]; then
            AUDIO_SYSTEM="alsa"
        fi
    fi
    
    echo
    
    # Configure MPD for detected audio system
    log_info "Configuring MPD for optimal audio..."
    
    # Generate MPD configuration with proper audio setup
    mkdir -p docker
    
    cat > docker/mpd.conf << EOF
# MPD Configuration for Docker - Auto-configured for $AUDIO_SYSTEM
bind_to_address     "0.0.0.0"
port                "6600"
music_directory     "/music"
db_file             "/var/lib/mpd/mpd.db"
log_file            "/var/log/mpd/mpd.log"
state_file          "/var/lib/mpd/mpdstate"
playlist_directory  "/var/lib/mpd/playlists"
pid_file            "/var/lib/mpd/mpd.pid"

EOF
    
    # Add audio outputs based on detected system
    if [ "$PULSE_AVAILABLE" = true ]; then
        cat >> docker/mpd.conf << EOF
# PulseAudio Output (primary audio system)
audio_output {
    type        "pulse"
    name        "PulseAudio System Output"
    enabled     "yes"
    server      "unix:/run/user/$USER_ID/pulse/native"
}

EOF
        # Store pulse socket for docker-compose
        echo "PULSE_SOCKET_PATH=/run/user/$USER_ID/pulse" >> .audio_env
    fi
    
    if [ "$ALSA_AVAILABLE" = true ]; then
        cat >> docker/mpd.conf << EOF
# ALSA Output (direct hardware access)
audio_output {
    type        "alsa"
    name        "ALSA System Output"
    enabled     "yes"
    device      "default"
    mixer_type  "software"
}

EOF
    fi
    
    # Always add HTTP streaming
    cat >> docker/mpd.conf << EOF
# HTTP Streaming (web access)
audio_output {
    type        "httpd"
    name        "Web Audio Stream" 
    encoder     "lame"
    port        "8002"
    bind_to_address "0.0.0.0"
    bitrate     "320"
    format      "44100:16:2"
    always_on   "yes"
    enabled     "yes"
}

# Performance settings
max_connections         "20"
connection_timeout      "60"
follow_outside_symlinks "yes"
follow_inside_symlinks  "yes"
auto_update             "yes"
save_absolute_paths_in_playlists "no"

# Logging
log_level               "notice"
EOF
    
    log_success "MPD audio configuration completed"
    echo "   • Audio system: $AUDIO_SYSTEM"
    echo "   • HTTP streaming: enabled on port 8002"
    if [ "$PULSE_AVAILABLE" = true ]; then
        echo "   • PulseAudio: configured for user $CURRENT_USER"
    fi
    if [ "$ALSA_AVAILABLE" = true ]; then
        echo "   • ALSA: configured for hardware access"
    fi
}

echo "=========================================="
echo "🎵 MPD Web Control - Docker Setup"
echo "=========================================="
echo

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

log_info "Working directory: $SCRIPT_DIR"
echo

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker is required but not installed."
    echo "   Please install Docker and try again."
    echo "   https://docs.docker.com/get-docker/"
    exit 1
fi

if ! command -v docker-compose >/dev/null 2>&1; then
    log_error "Docker Compose is required but not installed."
    echo "   Please install Docker Compose and try again."
    exit 1
fi

log_success "Docker and Docker Compose are available"
echo

# Check if user is in docker group
if ! groups "$USER" | grep -q docker; then
    log_warning "User $USER is not in the 'docker' group"
    echo "   You may need to use sudo with Docker commands"
    echo "   To fix: sudo usermod -aG docker $USER && newgrp docker"
    echo
fi

# Configuration wizard
log_info "Starting configuration wizard..."
echo

# Music directory
while true; do
    echo "📁 Music Library Configuration"
    echo "=============================="
    read -p "Enter path to your music directory: " MUSIC_DIR
    
    if [ -d "$MUSIC_DIR" ]; then
        # Expand path to absolute
        MUSIC_DIR=$(realpath "$MUSIC_DIR")
        log_success "Music directory found: $MUSIC_DIR"
        break
    else
        log_error "Directory not found: $MUSIC_DIR"
        echo "   Please enter a valid path to your music collection"
        echo
    fi
done

echo

# Web port
echo "🌐 Web Interface Configuration"
echo "=============================="
read -p "Web interface port [5003]: " WEB_PORT
WEB_PORT=${WEB_PORT:-5003}

# MPD external port
read -p "MPD external port [6600]: " MPD_EXTERNAL_PORT
MPD_EXTERNAL_PORT=${MPD_EXTERNAL_PORT:-6600}

echo

# Theme selection
echo "🎨 Theme Selection"
echo "=================="
echo "1) Dark (default)"
echo "2) Light"
echo "3) High Contrast"
echo "4) Desert"
read -p "Choose theme (1-4): " THEME_CHOICE

case $THEME_CHOICE in
    2) DEFAULT_THEME="light" ;;
    3) DEFAULT_THEME="high-contrast" ;;
    4) DEFAULT_THEME="desert" ;;
    *) DEFAULT_THEME="dark" ;;
esac

log_success "Theme set to: $DEFAULT_THEME"
echo

# Last.fm configuration
echo "🎵 Last.fm Integration (Optional)"
echo "================================="
echo "Get your API key and shared secret from https://www.last.fm/api"
echo
read -p "Enter Last.fm API Key (or press Enter to skip): " LASTFM_KEY
if [ -n "$LASTFM_KEY" ]; then
    read -p "Enter Last.fm Shared Secret: " LASTFM_SECRET
else
    LASTFM_SECRET=""
fi

echo

# MPD setup choice
echo "🎶 MPD Configuration"
echo "==================="
echo "1) Install containerized MPD (recommended - full control, audio streaming)"
echo "2) Connect to existing MPD server"
echo
read -p "Choose MPD setup (1-2): " MPD_CHOICE

if [ "$MPD_CHOICE" = "2" ]; then
    echo
    echo "📡 External MPD Server Configuration"
    echo "===================================="
    echo "1) localhost (MPD running on this machine)"
    echo "2) Remote server (IP address)"
    echo
    read -p "Choose connection type (1-2): " CONNECTION_TYPE
    
    if [ "$CONNECTION_TYPE" = "2" ]; then
        read -p "Enter MPD server IP address: " MPD_HOST
        while [[ ! $MPD_HOST =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; do
            echo "Please enter a valid IP address (e.g., 192.168.1.100)"
            read -p "Enter MPD server IP address: " MPD_HOST
        done
    else
        MPD_HOST="localhost"
    fi
    
    read -p "Enter MPD port [6600]: " MPD_PORT
    MPD_PORT=${MPD_PORT:-6600}
    USE_CONTAINERIZED_MPD=false
    
    # Test connection to external MPD
    log_info "Testing connection to MPD at $MPD_HOST:$MPD_PORT..."
    if command -v nc >/dev/null 2>&1; then
        if nc -z "$MPD_HOST" "$MPD_PORT" 2>/dev/null; then
            log_success "Successfully connected to MPD at $MPD_HOST:$MPD_PORT"
        else
            log_warning "Cannot connect to MPD at $MPD_HOST:$MPD_PORT"
            echo "   Make sure MPD is running and accessible"
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_error "Setup cancelled"
                exit 1
            fi
        fi
    fi
else
    MPD_HOST="mpd"
    MPD_PORT="6600"
    USE_CONTAINERIZED_MPD=true
    
    # Configure audio for containerized MPD
    log_info "Configuring audio system for containerized MPD..."
    configure_audio_system
fi

# Generate .env file
log_info "Generating configuration file..."

cat > .env << EOF
# MPD Web Control - Docker Configuration
# Generated on $(date)

# Music Library
MUSIC_DIRECTORY=$MUSIC_DIR

# Web Interface
WEB_PORT=$WEB_PORT
APP_PORT=5003
APP_HOST=0.0.0.0

# MPD Configuration
MPD_HOST=$MPD_HOST
MPD_PORT=$MPD_PORT
MPD_EXTERNAL_PORT=$MPD_EXTERNAL_PORT
MPD_TIMEOUT=10

# Theme Settings
DEFAULT_THEME=$DEFAULT_THEME

# Last.fm Integration
LASTFM_API_KEY=$LASTFM_KEY
LASTFM_SHARED_SECRET=$LASTFM_SECRET

# Auto-Fill Settings
AUTO_FILL_ENABLED=true
RECENT_MUSIC_DIRS=

# Security
SECRET_KEY=$(openssl rand -hex 32 2>/dev/null || echo "mpd-web-control-$(date +%s)")

# Production Settings
FLASK_ENV=production
EOF

log_success "Configuration saved to .env"
echo

# Create data directory
log_info "Creating data directory..."
mkdir -p data
chmod 755 data
log_success "Data directory created"

# Build and start services
log_info "Building and starting services..."
echo

# Load audio environment if exists
if [ -f .audio_env ]; then
    source .audio_env
fi

# Update docker-compose.yml with current user ID for audio access
if [ "$USE_CONTAINERIZED_MPD" = true ]; then
    log_info "Configuring Docker containers for audio access..."
    
    # Update .env with audio settings
    cat >> .env << EOF

# Audio Configuration (auto-detected)
USER_ID=$(id -u)
PULSE_SOCKET_PATH=${PULSE_SOCKET_PATH:-/run/user/$(id -u)/pulse}
EOF

    log_info "Starting with containerized MPD and audio configuration..."
    docker-compose --profile with-mpd up -d --build
    
    # Test audio setup
    sleep 3
    log_info "Testing audio configuration..."
    
    # Check if MPD can access audio devices
    if docker-compose logs mpd 2>/dev/null | grep -q "output.*opened"; then
        log_success "MPD audio output successfully configured"
    elif docker-compose logs mpd 2>/dev/null | grep -q "Failed to open"; then
        log_warning "MPD audio setup may have issues - check audio permissions"
        echo "   Try: sudo usermod -aG audio $USER && newgrp audio"
    fi
else
    log_info "Starting web interface only (connecting to external MPD at $MPD_HOST:$MPD_PORT)..."
    docker-compose up -d --build web
fi

# Wait for services to be ready
log_info "Waiting for services to start..."
sleep 5

# Check service health
if [ "$USE_CONTAINERIZED_MPD" = true ]; then
    if docker-compose ps | grep -q "mpd-server.*Up"; then
        log_success "MPD container is running"
    else
        log_warning "MPD container may have issues - check logs with: docker-compose logs mpd"
    fi
fi

if docker-compose ps | grep -q "mpd-web-control.*Up"; then
    log_success "Web interface is running"
else
    log_warning "Web interface may have issues - check logs with: docker-compose logs web"
fi

echo
echo "=========================================="
log_success "Docker setup completed!"
echo "=========================================="
echo
log_info "Services are running:"
echo "  • Web Interface: http://localhost:$WEB_PORT"
if [ "$USE_CONTAINERIZED_MPD" = true ]; then
    echo "  • MPD Server: localhost:$MPD_EXTERNAL_PORT"
    echo "  • Audio Stream: http://localhost:8002"
fi
echo
echo "📁 Music Directory: $MUSIC_DIR"
echo "🎨 Theme: $DEFAULT_THEME"
echo
log_info "Useful commands:"
echo "  docker-compose ps                    # Check service status"
echo "  docker-compose logs web              # View web app logs"
if [ "$USE_CONTAINERIZED_MPD" = true ]; then
    echo "  docker-compose logs mpd              # View MPD logs"
fi
echo "  docker-compose down                  # Stop all services"
echo "  docker-compose up -d                 # Restart services"
echo "  ./uninstall.sh                       # Complete cleanup"
echo
echo "🎉 Your containerized Maestro MPD setup is ready!"