#!/bin/bash

# MPD Web Control - Unified Setup Script
# Intelligently detects and configures both native and containerized setups

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

echo "=========================================="
echo "🎵 MPD Web Control - Unified Setup"
echo "=========================================="
echo

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   log_error "This script should not be run as root. Please run as a regular user."
   exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

log_info "Working directory: $SCRIPT_DIR"
echo

# Function to check if MPD is already installed and running
check_existing_mpd() {
    log_info "Checking for existing MPD installation..."
    
    MPD_NATIVE_RUNNING=false
    MPD_NATIVE_INSTALLED=false
    MPD_PORT_IN_USE=false
    
    # Check if MPD is installed
    if command -v mpd >/dev/null 2>&1; then
        MPD_NATIVE_INSTALLED=true
        log_success "Native MPD is installed"
        
        # Check if MPD service is running
        if systemctl is-active --quiet mpd 2>/dev/null || pgrep -f "mpd" >/dev/null 2>&1; then
            MPD_NATIVE_RUNNING=true
            log_success "Native MPD is currently running"
        fi
    fi
    
    # Check if something is using port 6600
    if command -v nc >/dev/null 2>&1; then
        if nc -z localhost 6600 2>/dev/null; then
            MPD_PORT_IN_USE=true
            log_success "MPD service is accessible on port 6600"
        fi
    fi
    
    echo
}

# Function to detect Docker availability
check_docker() {
    log_info "Checking Docker availability..."
    
    DOCKER_AVAILABLE=false
    DOCKER_COMPOSE_AVAILABLE=false
    
    if command -v docker >/dev/null 2>&1; then
        if docker ps >/dev/null 2>&1 || sudo docker ps >/dev/null 2>&1; then
            DOCKER_AVAILABLE=true
            log_success "Docker is available"
        else
            log_warning "Docker is installed but not accessible (may need sudo or user group)"
        fi
    else
        log_warning "Docker is not installed"
    fi
    
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_AVAILABLE=true
        log_success "Docker Compose is available"
    else
        log_warning "Docker Compose is not installed"
    fi
    
    echo
}

# Function to present setup options based on what's available
present_setup_options() {
    echo "🔧 Setup Options"
    echo "================"
    
    option_num=1
    declare -g -A SETUP_OPTIONS
    
    # Option 1: Use existing MPD if available
    if [ "$MPD_PORT_IN_USE" = true ]; then
        echo "$option_num) Use existing MPD server (detected on port 6600)"
        SETUP_OPTIONS[$option_num]="existing_mpd"
        ((option_num++))
    fi
    
    # Option 2: Install native Python setup (always available)
    echo "$option_num) Native Python setup (requires manual MPD installation)"
    SETUP_OPTIONS[$option_num]="native_python"
    ((option_num++))
    
    # Option 3: Docker setup if available
    if [ "$DOCKER_AVAILABLE" = true ] && [ "$DOCKER_COMPOSE_AVAILABLE" = true ]; then
        echo "$option_num) Containerized setup (Docker - includes MPD + web interface)"
        SETUP_OPTIONS[$option_num]="docker_full"
        ((option_num++))
    fi
    
    # Option 4: Manual Docker connection if available
    if [ "$DOCKER_AVAILABLE" = true ] && [ "$DOCKER_COMPOSE_AVAILABLE" = true ]; then
        echo "$option_num) Containerized web interface only (connect to external MPD)"
        SETUP_OPTIONS[$option_num]="docker_web_only"
        ((option_num++))
    fi
    
    echo
    read -p "Choose setup option [1-$((option_num-1))]: " SETUP_CHOICE
    
    CHOSEN_SETUP=${SETUP_OPTIONS[$SETUP_CHOICE]}
    
    if [ -z "$CHOSEN_SETUP" ]; then
        log_error "Invalid choice. Please run setup again."
        exit 1
    fi
    
    log_success "Selected: $CHOSEN_SETUP"
    echo
}

# Function for existing MPD setup
setup_existing_mpd() {
    log_info "Setting up web interface for existing MPD..."
    
    # Check Python and set up virtual environment
    setup_python_environment
    
    # Create basic config
    create_basic_config "localhost" "6600"
    
    log_success "Setup completed for existing MPD!"
    echo
    echo "🚀 To start the web interface:"
    echo "   source venv/bin/activate"
    echo "   python app.py"
    echo
    echo "🌐 Web interface will be available at: http://localhost:5003"
}

# Function for native Python setup
setup_native_python() {
    log_info "Setting up native Python installation..."
    
    # Check Python and set up virtual environment
    setup_python_environment
    
    # Check if MPD is installed, offer to install if not
    if [ "$MPD_NATIVE_INSTALLED" = false ]; then
        echo
        log_warning "MPD is not installed on this system"
        echo "Options:"
        echo "1) Install MPD now (requires sudo)"
        echo "2) Continue without MPD (you'll need to install it manually)"
        echo "3) Switch to containerized setup instead"
        echo
        read -p "Choose option [1-3]: " MPD_INSTALL_CHOICE
        
        case $MPD_INSTALL_CHOICE in
            1)
                install_native_mpd
                ;;
            2)
                log_warning "MPD not installed - you'll need to install it manually"
                ;;
            3)
                log_info "Switching to containerized setup..."
                setup_docker_full
                return
                ;;
            *)
                log_error "Invalid choice"
                exit 1
                ;;
        esac
    fi
    
    # Create config for local MPD
    create_basic_config "localhost" "6600"
    
    log_success "Native Python setup completed!"
    echo
    echo "🚀 To start the web interface:"
    echo "   source venv/bin/activate" 
    echo "   python app.py"
    echo
    echo "🌐 Web interface will be available at: http://localhost:5003"
    
    if [ "$MPD_NATIVE_RUNNING" = false ]; then
        echo
        log_warning "Don't forget to start MPD:"
        echo "   sudo systemctl start mpd"
        echo "   sudo systemctl enable mpd  # to start automatically"
    fi
}

# Function to install native MPD
install_native_mpd() {
    log_info "Installing MPD..."
    
    # Detect distribution and install MPD
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y mpd mpc
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y mpd mpc
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm mpd mpc
    else
        log_error "Cannot auto-install MPD on this system. Please install manually."
        exit 1
    fi
    
    # Basic MPD configuration
    sudo mkdir -p /etc/mpd
    read -p "Enter path to your music directory: " MUSIC_DIR
    
    sudo tee /etc/mpd/mpd.conf > /dev/null << EOF
music_directory     "$MUSIC_DIR"
db_file             "/var/lib/mpd/mpd.db"
log_file            "/var/log/mpd/mpd.log"
state_file          "/var/lib/mpd/mpdstate"
playlist_directory  "/var/lib/mpd/playlists"

bind_to_address     "localhost"
port                "6600"

audio_output {
    type    "pulse"
    name    "PulseAudio"
}

audio_output {
    type    "alsa"
    name    "ALSA"
}
EOF
    
    # Start MPD service
    sudo systemctl enable mpd
    sudo systemctl start mpd
    
    log_success "MPD installed and started"
}

# Function for Docker full setup
setup_docker_full() {
    log_info "Setting up containerized MPD + web interface..."
    
    # Run the docker configuration
    configure_docker_setup true
}

# Function for Docker web-only setup  
setup_docker_web_only() {
    log_info "Setting up containerized web interface only..."
    
    echo "📡 External MPD Configuration"
    echo "============================="
    read -p "Enter MPD host [localhost]: " MPD_HOST
    MPD_HOST=${MPD_HOST:-localhost}
    read -p "Enter MPD port [6600]: " MPD_PORT
    MPD_PORT=${MPD_PORT:-6600}
    
    # Test connection
    if command -v nc >/dev/null 2>&1; then
        if nc -z "$MPD_HOST" "$MPD_PORT" 2>/dev/null; then
            log_success "Successfully connected to MPD at $MPD_HOST:$MPD_PORT"
        else
            log_warning "Cannot connect to MPD at $MPD_HOST:$MPD_PORT"
            echo "   Make sure MPD is running and accessible"
        fi
    fi
    
    # Run docker configuration for web-only
    configure_docker_setup false "$MPD_HOST" "$MPD_PORT"
}

# Function to set up Python environment
setup_python_environment() {
    log_info "Setting up Python environment..."
    
    # Check Python version
    PYTHON_VERSION=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    REQUIRED_VERSION="3.7"

    if python3 -c "import sys; exit(0 if sys.version_info >= (3,7) else 1)"; then
        log_success "Python $PYTHON_VERSION detected (>= $REQUIRED_VERSION required)"
    else
        log_error "Python $REQUIRED_VERSION or higher is required. Found: $PYTHON_VERSION"
        exit 1
    fi

    # Create virtual environment if it doesn't exist
    if [ ! -d "venv" ]; then
        log_info "Creating virtual environment..."
        python3 -m venv venv
        log_success "Virtual environment created"
    else
        log_success "Virtual environment already exists"
    fi

    # Activate virtual environment
    log_info "Installing Python dependencies..."
    source venv/bin/activate

    # Upgrade pip and install requirements
    pip install --upgrade pip >/dev/null 2>&1
    pip install -r requirements.txt >/dev/null 2>&1

    log_success "Python dependencies installed"
}

# Function to create basic configuration
create_basic_config() {
    local mpd_host=$1
    local mpd_port=$2
    
    log_info "Creating configuration..."
    
    if [ ! -f "config.env" ]; then
        cp config.env.example config.env
        
        # Update with provided MPD settings
        sed -i "s|MPD_HOST=.*|MPD_HOST=$mpd_host|" config.env
        sed -i "s|MPD_PORT=.*|MPD_PORT=$mpd_port|" config.env
        
        # Ask for music directory
        read -p "Enter path to your music directory [/home/$USER/Music]: " MUSIC_DIR
        MUSIC_DIR=${MUSIC_DIR:-/home/$USER/Music}
        sed -i "s|MUSIC_DIRECTORY=.*|MUSIC_DIRECTORY=$MUSIC_DIR|" config.env
        
        log_success "Configuration file created: config.env"
    else
        log_success "Configuration file already exists: config.env"
    fi
}

# Function to configure Docker setup (reuse logic from docker-setup.sh)
configure_docker_setup() {
    local include_mpd=$1
    local external_host=$2
    local external_port=$3
    
    # Music directory
    read -p "Enter path to your music directory: " MUSIC_DIR
    while [ ! -d "$MUSIC_DIR" ]; do
        log_error "Directory not found: $MUSIC_DIR"
        read -p "Enter path to your music directory: " MUSIC_DIR
    done
    MUSIC_DIR=$(realpath "$MUSIC_DIR")
    
    # Port configuration
    read -p "Web interface port [5003]: " WEB_PORT
    WEB_PORT=${WEB_PORT:-5003}
    
    # Theme selection
    echo
    echo "🎨 Theme Selection"
    echo "1) Dark (default) 2) Light 3) High Contrast 4) Desert"
    read -p "Choose theme [1]: " THEME_CHOICE
    case $THEME_CHOICE in
        2) DEFAULT_THEME="light" ;;
        3) DEFAULT_THEME="high-contrast" ;;
        4) DEFAULT_THEME="desert" ;;
        *) DEFAULT_THEME="dark" ;;
    esac
    
    # Generate .env file
    cat > .env << EOF
MUSIC_DIRECTORY=$MUSIC_DIR
WEB_PORT=$WEB_PORT
APP_PORT=5003
APP_HOST=0.0.0.0
DEFAULT_THEME=$DEFAULT_THEME
MPD_TIMEOUT=10
SECRET_KEY=$(openssl rand -hex 32 2>/dev/null || echo "mpd-web-control-$(date +%s)")
FLASK_ENV=production
EOF

    if [ "$include_mpd" = true ]; then
        echo "MPD_HOST=mpd" >> .env
        echo "MPD_PORT=6600" >> .env
        echo "MPD_EXTERNAL_PORT=6600" >> .env
        
        # Configure audio and start with MPD
        configure_audio_for_docker
        docker-compose --profile with-mpd up -d --build
    else
        echo "MPD_HOST=$external_host" >> .env
        echo "MPD_PORT=$external_port" >> .env
        
        # Start web interface only
        docker-compose up -d --build web
    fi
    
    log_success "Docker setup completed!"
    echo "🌐 Web interface: http://localhost:$WEB_PORT"
}

# Function to configure audio for Docker (simplified from docker-setup.sh)
configure_audio_for_docker() {
    log_info "Configuring audio for containerized MPD..."
    
    USER_ID=$(id -u)
    
    # Add user to audio group if needed
    if ! groups "$USER" | grep -q audio; then
        sudo usermod -aG audio "$USER"
        log_warning "Added to audio group - may need logout/login"
    fi
    
    # Create MPD config with audio
    mkdir -p docker
    cat > docker/mpd.conf << EOF
bind_to_address     "0.0.0.0"
port                "6600"
music_directory     "/music"
db_file             "/var/lib/mpd/mpd.db"
log_file            "/var/log/mpd/mpd.log"
state_file          "/var/lib/mpd/mpdstate"
playlist_directory  "/var/lib/mpd/playlists"

audio_output {
    type        "pulse"
    name        "PulseAudio"
    enabled     "yes"
    server      "unix:/run/user/$USER_ID/pulse/native"
}

audio_output {
    type        "alsa" 
    name        "ALSA"
    enabled     "yes"
}

audio_output {
    type        "httpd"
    name        "Web Stream"
    encoder     "lame"
    port        "8002"
    bind_to_address "0.0.0.0"
    bitrate     "320"
    format      "44100:16:2"
    always_on   "yes"
    enabled     "yes"
}

max_connections     "10"
connection_timeout  "60"
auto_update         "yes"
EOF
    
    # Add audio settings to .env
    cat >> .env << EOF
USER_ID=$USER_ID
PULSE_SOCKET_PATH=/run/user/$USER_ID/pulse
EOF

    log_success "Audio configuration completed"
}

# Main execution flow
main() {
    check_existing_mpd
    check_docker
    present_setup_options
    
    case $CHOSEN_SETUP in
        "existing_mpd")
            setup_existing_mpd
            ;;
        "native_python")
            setup_native_python
            ;;
        "docker_full")
            setup_docker_full
            ;;
        "docker_web_only")
            setup_docker_web_only
            ;;
        *)
            log_error "Unknown setup type: $CHOSEN_SETUP"
            exit 1
            ;;
    esac
    
    echo
    echo "🎉 Setup completed successfully!"
    echo
    log_info "Useful commands:"
    echo "  ./uninstall.sh        # Complete cleanup and reset"
    if [ -f ".env" ]; then
        echo "  docker-compose ps     # Check container status"
        echo "  docker-compose logs   # View logs"
    fi
    echo
}

# Run main function
main "$@"