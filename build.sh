#!/bin/bash
set -e

# ImageMagick Portable Self-Contained Build Script
# Builds ImageMagick with all dependencies statically linked for portability
# Usage: ./build.sh [TAG] [ARCH]
# Examples:
#   ./build.sh 7.1.2-27 amd64      # Build specific tag for amd64
#   ./build.sh 7.1.2-27 arm64      # Build specific tag for arm64
#   ./build.sh                      # Build latest for current architecture

# Configuration
IMAGEMAGICK_REPO="https://github.com/ImageMagick/ImageMagick.git"
RELEASE_TAG="${1:-latest}"
TARGET_ARCH="${2:-$(uname -m)}"
WORK_DIR="${PWD}/build-work"
BUILD_DIR="${PWD}/build"
PREFIX="${WORK_DIR}/install"

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

# Function to install build dependencies
install_dependencies() {
    log_info "Installing build dependencies..."
    
    if ! command -v apt-get &> /dev/null; then
        log_error "apt-get not found. This script is designed for Debian/Ubuntu systems."
        exit 1
    fi
    
    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        pkg-config \
        git \
        curl \
        wget \
        autoconf \
        automake \
        libtool \
        cmake \
        nasm
    
    log_info "Build dependencies installed successfully"
}

# Function to build a static dependency
build_zlib() {
    log_info "Building zlib..."
    cd "$WORK_DIR"
    
    if [ ! -d "zlib" ]; then
        git clone --depth 1 https://github.com/madler/zlib.git
    fi
    
    cd zlib
    ./configure --static --prefix="$PREFIX"
    make -j$(nproc)
    make install
    cd ..
}

build_jpeg() {
    log_info "Building libjpeg-turbo..."
    cd "$WORK_DIR"
    
    if [ ! -d "libjpeg-turbo" ]; then
        git clone --depth 1 https://github.com/libjpeg-turbo/libjpeg-turbo.git
    fi
    
    cd libjpeg-turbo
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
           -DENABLE_SHARED=OFF \
           -DENABLE_STATIC=ON \
           ..
    make -j$(nproc)
    make install
    cd ../..
}

build_png() {
    log_info "Building libpng..."
    cd "$WORK_DIR"
    
    if [ ! -d "libpng" ]; then
        git clone --depth 1 https://github.com/glennrp/libpng.git
    fi
    
    cd libpng
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --with-zlib-prefix="$PREFIX"
    make -j$(nproc)
    make install
    cd ..
}

build_freetype() {
    log_info "Building freetype..."
    cd "$WORK_DIR"
    
    if [ ! -d "freetype" ]; then
        git clone --depth 1 https://git.savannah.gnu.org/git/freetype/freetype2.git freetype
    fi
    
    cd freetype
    ./autogen.sh
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --with-zlib="$PREFIX"
    make -j$(nproc)
    make install
    cd ..
}

build_webp() {
    log_info "Building libwebp..."
    cd "$WORK_DIR"
    
    if [ ! -d "libwebp" ]; then
        git clone --depth 1 https://github.com/webmproject/libwebp.git
    fi
    
    cd libwebp
    ./autogen.sh
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static
    make -j$(nproc)
    make install
    cd ..
}

build_tiff() {
    log_info "Building libtiff..."
    cd "$WORK_DIR"
    
    if [ ! -d "libtiff" ]; then
        git clone --depth 1 https://gitlab.com/libtiff/libtiff.git
    fi
    
    cd libtiff
    ./autogen.sh
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --with-zlib-include-dir="$PREFIX/include" \
                --with-zlib-lib-dir="$PREFIX/lib" \
                --with-jpeg-include-dir="$PREFIX/include" \
                --with-jpeg-lib-dir="$PREFIX/lib"
    make -j$(nproc)
    make install
    cd ..
}

build_fontconfig() {
    log_info "Building fontconfig..."
    cd "$WORK_DIR"
    
    if [ ! -d "fontconfig" ]; then
        git clone --depth 1 https://gitlab.freedesktop.org/fontconfig/fontconfig.git
    fi
    
    cd fontconfig
    ./autogen.sh
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --with-freetype-config="$PREFIX/bin/freetype-config"
    make -j$(nproc)
    make install
    cd ..
}

# Function to fetch and checkout ImageMagick source
fetch_imagemagick() {
    local tag=$1
    
    log_info "Fetching ImageMagick source..."
    
    if [ -d "$WORK_DIR/ImageMagick" ]; then
        log_info "Updating existing ImageMagick repository..."
        cd "$WORK_DIR/ImageMagick"
        git fetch origin
        cd "$WORK_DIR"
    else
        log_info "Cloning ImageMagick repository..."
        cd "$WORK_DIR"
        git clone "$IMAGEMAGICK_REPO" ImageMagick
    fi
    
    cd "$WORK_DIR/ImageMagick"
    
    if [ "$tag" = "latest" ]; then
        log_info "Checking out latest release..."
        git checkout $(git describe --tags --abbrev=0 2>/dev/null || git rev-parse HEAD)
    else
        log_info "Checking out tag: $tag..."
        git checkout "$tag"
    fi
    
    CHECKED_OUT_TAG=$(git describe --tags 2>/dev/null || git rev-parse --short HEAD)
    log_info "Checked out: $CHECKED_OUT_TAG"
    
    cd "$WORK_DIR"
}

# Function to build ImageMagick statically
build_imagemagick() {
    log_info "Building ImageMagick with static dependencies..."
    
    cd "$WORK_DIR/ImageMagick"
    
    # Export library paths for compilation
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
    export LDFLAGS="-static -L$PREFIX/lib"
    export CPPFLAGS="-I$PREFIX/include"
    export LD_LIBRARY_PATH="$PREFIX/lib:$LD_LIBRARY_PATH"
    
    log_info "Running configure..."
    ./configure \
        --prefix="$PREFIX/imagemagick" \
        --enable-static \
        --disable-shared \
        --with-quantum-depth=16 \
        --enable-hdri \
        --with-magick-plus-plus \
        --with-zlib="$PREFIX" \
        --with-jpeg="$PREFIX" \
        --with-png="$PREFIX" \
        --with-freetype="$PREFIX" \
        --with-webp="$PREFIX" \
        --with-tiff="$PREFIX" \
        --with-fontconfig="$PREFIX" \
        --disable-docs \
        --enable-cipher
    
    log_info "Compiling ImageMagick (using $(nproc) cores)..."
    make -j$(nproc)
    
    log_info "Installing..."
    make install
    
    cd "$WORK_DIR"
}

# Function to strip and compress binaries
optimize_binaries() {
    log_info "Stripping and optimizing binaries..."
    
    find "$PREFIX/imagemagick" -type f -executable -exec strip {} \; 2>/dev/null || true
    find "$PREFIX/imagemagick" -name "*.a" -exec strip --strip-unneeded {} \; 2>/dev/null || true
}

# Function to create portable tarball
create_portable_tarball() {
    local tag=$1
    local arch=$2
    
    log_info "Creating portable tarball..."
    
    mkdir -p "$BUILD_DIR"
    
    # Copy only runtime essentials (no static libs, only executables and runtime libs)
    local temp_dir="${WORK_DIR}/portable"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir/imagemagick-${tag}-${arch}"
    
    # Copy binaries
    cp -r "$PREFIX/imagemagick/bin" "$temp_dir/imagemagick-${tag}-${arch}/" || true
    
    # Copy shared libs if any were built
    mkdir -p "$temp_dir/imagemagick-${tag}-${arch}/lib"
    if [ -d "$PREFIX/imagemagick/lib" ]; then
        cp "$PREFIX/imagemagick/lib"/*.so* "$temp_dir/imagemagick-${tag}-${arch}/lib/" 2>/dev/null || true
    fi
    
    # Create README with installation and usage info
    cat > "$temp_dir/imagemagick-${tag}-${arch}/README.md" << 'EOF'
# ImageMagick Portable Build

This is a self-contained, portable build of ImageMagick with all dependencies statically linked.

## Installation

### Option 1: Add to PATH
```bash
export PATH="$(pwd)/bin:$PATH"
```

### Option 2: Install to system
```bash
sudo cp -r * /usr/local/
```

### Option 3: Use directly
```bash
./bin/convert image.jpg -resize 100x100 thumbnail.jpg
./bin/identify image.jpg
```

## Included Binaries

- `convert` - Image conversion tool
- `identify` - Image information tool
- `display` - Image display tool
- `animate` - Animation tool
- `composite` - Image composition tool
- `mogrify` - In-place image modification tool
- And more...

## Static Build Details

This build includes:
- zlib
- libjpeg-turbo
- libpng
- freetype
- libwebp
- libtiff
- fontconfig

All dependencies are statically linked, making this build portable across different systems.

## Usage Examples

```bash
# Convert image format
./bin/convert input.png output.jpg

# Resize image
./bin/convert input.jpg -resize 800x600 output.jpg

# Get image info
./bin/identify image.jpg

# Create thumbnail
./bin/convert image.jpg -thumbnail 100x100 thumb.jpg
```

## Requirements

This build is self-contained and should work on any Linux system with glibc.
No additional dependencies need to be installed.

EOF

    # Create tarball
    cd "$temp_dir"
    tar -czf "${BUILD_DIR}/imagemagick-${tag}-linux-${arch}.tar.gz" "imagemagick-${tag}-${arch}/"
    cd - > /dev/null
    
    log_info "Portable tarball created: $(pwd)/build/imagemagick-${tag}-linux-${arch}.tar.gz"
    ls -lh "${BUILD_DIR}/imagemagick-${tag}-linux-${arch}.tar.gz"
    
    # Show tarball contents
    log_info "Tarball contents:"
    tar -tzf "${BUILD_DIR}/imagemagick-${tag}-linux-${arch}.tar.gz" | head -20
}

# Function to display usage
usage() {
    cat << EOF
ImageMagick Portable Self-Contained Build Script

Builds a fully static, portable ImageMagick binary with all dependencies
embedded. No external dependencies required on the target system.

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

Output:
    - Portable tarball: build/imagemagick-<tag>-linux-<arch>.tar.gz
    - Build directory: build-work/
    - Installed at: build-work/install/imagemagick/

Notes:
    - Requires Ubuntu 22.04 or similar Debian-based system
    - First build will take significant time (~30-60 minutes)
    - Subsequent builds are faster due to cached dependencies
    - Resulting binary is self-contained and portable
    - All dependencies are statically linked
    - ~200-300MB tarball size (before compression)

EOF
}

# Cleanup on error
cleanup_on_error() {
    log_error "Build failed"
    log_warn "Build directory retained for debugging: $WORK_DIR"
    exit 1
}

trap cleanup_on_error ERR

# Main script
main() {
    log_info "ImageMagick Portable Self-Contained Build"
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
        log_error "Cross-compilation for arm64 on amd64 is not supported for this static build"
        log_warn "Please run this script natively on arm64 hardware"
        exit 1
    fi
    if [ "$CURRENT_ARCH" = "aarch64" ] && [ "$TARGET_ARCH" = "amd64" ]; then
        log_error "Cross-compilation for amd64 on arm64 is not supported for this static build"
        log_warn "Please run this script natively on amd64 hardware"
        exit 1
    fi
    
    # Create work directory
    mkdir -p "$WORK_DIR"
    mkdir -p "$BUILD_DIR"
    
    log_info "Work directory: $WORK_DIR"
    log_info "Build output directory: $BUILD_DIR"
    
    # Install build dependencies
    install_dependencies
    
    # Build all static dependencies
    log_info "Building static dependencies..."
    build_zlib
    build_jpeg
    build_png
    build_freetype
    build_webp
    build_tiff
    build_fontconfig
    
    # Fetch and build ImageMagick
    fetch_imagemagick "$RELEASE_TAG"
    build_imagemagick
    optimize_binaries
    
    # Get the actual checked out tag
    ACTUAL_TAG=$CHECKED_OUT_TAG
    
    # Create portable tarball
    create_portable_tarball "$ACTUAL_TAG" "$TARGET_ARCH"
    
    log_info "================================"
    log_info "Portable build completed!"
    log_info "Output: $(pwd)/build/imagemagick-${ACTUAL_TAG}-linux-${TARGET_ARCH}.tar.gz"
    log_info "================================"
    
    # Display usage instructions
    log_info ""
    log_info "To use the portable build:"
    log_info "  1. Extract: tar -xzf build/imagemagick-${ACTUAL_TAG}-linux-${TARGET_ARCH}.tar.gz"
    log_info "  2. Option A - Add to PATH: export PATH=\"\$(pwd)/imagemagick-${ACTUAL_TAG}-${TARGET_ARCH}/bin:\$PATH\""
    log_info "  3. Option B - Install: sudo cp -r imagemagick-${ACTUAL_TAG}-${TARGET_ARCH}/* /usr/local/"
    log_info "  4. Use: convert image.jpg -resize 100x100 thumb.jpg"
    
    log_info ""
    log_info "To clean up build artifacts:"
    log_info "  rm -rf build-work/"
}

# Run main function
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

main
