#!/bin/bash
set -e

# ImageMagick Local Build Script
# Builds ImageMagick from source for both amd64 and arm64
# Usage: ./build.sh [TAG] [ARCH]
# Examples:
#   ./build.sh 7.1.2-27 amd64      # Build specific tag for amd64
#   ./build.sh 7.1.2-27 arm64      # Build specific tag for arm64
#   ./build.sh                      # Build latest for current architecture

# Configuration
IMAGEMAGICK_REPO="https://github.com/ImageMagick/ImageMagick.git"
RELEASE_TAG="${1:-latest}"
TARGET_ARCH="${2:-$(uname -m)}"
BUILD_DIR="${PWD}/build"
INSTALL_PREFIX="/usr/local/imagemagick"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to install dependencies
install_dependencies() {
    local arch=$1
    log_info "Installing dependencies for $arch..."
    
    if ! command -v apt-get &> /dev/null; then
        log_error "apt-get not found. This script is designed for Debian/Ubuntu systems."
        exit 1
    fi
    
    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        pkg-config \
        libx11-dev \
        libxext-dev \
        libxcb1-dev \
        zlib1g-dev \
        libjpeg-dev \
        libpng-dev \
        libwebp-dev \
        libtiff-dev \
        libfreetype6-dev \
        libfontconfig1-dev \
        git \
        curl
    
    log_info "Dependencies installed successfully"
}

# Function to fetch and checkout ImageMagick source
fetch_imagemagick() {
    local tag=$1
    
    if [ -d "ImageMagick" ]; then
        log_info "Updating existing ImageMagick repository..."
        cd ImageMagick
        git fetch origin
        cd ..
    else
        log_info "Cloning ImageMagick repository..."
        git clone "$IMAGEMAGICK_REPO" ImageMagick
    fi
    
    cd ImageMagick
    
    if [ "$tag" = "latest" ]; then
        log_info "Checking out latest release..."
        git checkout $(git describe --tags --abbrev=0 2>/dev/null || git rev-parse HEAD)
    else
        log_info "Checking out tag: $tag..."
        git checkout "$tag"
    fi
    
    CHECKED_OUT_TAG=$(git describe --tags 2>/dev/null || git rev-parse --short HEAD)
    log_info "Checked out: $CHECKED_OUT_TAG"
    
    cd ..
}

# Function to build for a specific architecture
build_arch() {
    local arch=$1
    local src_dir="ImageMagick"
    local build_output="${BUILD_DIR}/${arch}"
    
    log_info "Building ImageMagick for $arch..."
    
    mkdir -p "$build_output"
    
    cd "$src_dir"
    
    log_info "Running configure for $arch..."
    ./configure \
        --prefix="$INSTALL_PREFIX-$arch" \
        --enable-shared \
        --disable-static \
        --with-quantum-depth=16 \
        --enable-hdri \
        --with-magick-plus-plus
    
    log_info "Compiling ImageMagick for $arch (using $(nproc) cores)..."
    make -j$(nproc)
    
    log_info "Installing to temporary directory..."
    make install DESTDIR="$build_output"
    
    cd ..
    
    log_info "Build for $arch completed successfully"
}

# Function to create tarball
create_tarball() {
    local arch=$1
    local tag=$2
    local build_output="${BUILD_DIR}/${arch}"
    local tarball_name="imagemagick-${tag}-linux-${arch}.tar.gz"
    
    log_info "Creating tarball: $tarball_name"
    
    cd "$build_output"
    tar -czf "${PWD}/../${tarball_name}" .
    cd - > /dev/null
    
    log_info "Tarball created: $(pwd)/build/${tarball_name}"
    ls -lh "build/${tarball_name}"
}

# Function to display usage
usage() {
    cat << EOF
ImageMagick Local Build Script

Usage: ./build.sh [OPTIONS]

Options:
    TAG         Release tag to build (default: latest)
                Example: 7.1.2-27
    
    ARCH        Target architecture (default: current system architecture)
                Options: amd64, arm64

Examples:
    # Build latest for current architecture
    ./build.sh

    # Build specific version for amd64
    ./build.sh 7.1.2-27 amd64

    # Build specific version for arm64
    ./build.sh 7.1.2-27 arm64

Notes:
    - Requires Ubuntu 22.04 or similar Debian-based system
    - arm64 builds require QEMU emulation (automatically installed)
    - Built artifacts are placed in ./build/ directory
    - Install prefix: $INSTALL_PREFIX-<arch>

EOF
}

# Main script
main() {
    log_info "ImageMagick Local Build Script"
    log_info "Tag: $RELEASE_TAG, Architecture: $TARGET_ARCH"
    
    # Validate architecture
    case $TARGET_ARCH in
        amd64|x86_64)
            TARGET_ARCH="amd64"
            ;;
        arm64|aarch64)
            TARGET_ARCH="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $TARGET_ARCH"
            log_warn "Supported architectures: amd64, arm64"
            exit 1
            ;;
    esac
    
    # Check if running on ARM but targeting AMD64 (or vice versa)
    CURRENT_ARCH=$(uname -m)
    if [ "$CURRENT_ARCH" = "x86_64" ] && [ "$TARGET_ARCH" = "arm64" ]; then
        log_warn "Cross-compiling for arm64 on amd64 system"
        log_warn "This requires QEMU emulation and may be slow"
        log_warn "Consider using native hardware for faster builds"
    fi
    
    # Create build directory
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # Install dependencies
    install_dependencies "$TARGET_ARCH"
    
    # Fetch ImageMagick source
    fetch_imagemagick "$RELEASE_TAG"
    
    # Get the actual checked out tag
    ACTUAL_TAG=$CHECKED_OUT_TAG
    
    # Build for target architecture
    if [ "$TARGET_ARCH" = "arm64" ] && [ "$CURRENT_ARCH" = "x86_64" ]; then
        log_info "Setting up QEMU for arm64 emulation..."
        sudo apt-get install -y qemu qemu-user-static binfmt-support
        
        log_warn "Building via QEMU emulation - this will be slow"
        log_info "For faster builds, run this script natively on arm64 hardware"
    fi
    
    build_arch "$TARGET_ARCH"
    create_tarball "$TARGET_ARCH" "$ACTUAL_TAG"
    
    log_info "================================"
    log_info "Build completed successfully!"
    log_info "Output: $(pwd)/imagemagick-${ACTUAL_TAG}-linux-${TARGET_ARCH}.tar.gz"
    log_info "================================"
    
    # Display installation instructions
    log_info "To install the built binaries, run:"
    echo "  sudo tar -xzf build/imagemagick-${ACTUAL_TAG}-linux-${TARGET_ARCH}.tar.gz -C /"
}

# Run main function
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

main
