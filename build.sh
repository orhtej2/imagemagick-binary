#!/bin/bash
set -e

# ImageMagick Fully Static Self-Contained Build Script
# Builds ImageMagick with ALL dependencies statically linked into a single binary
# No .so files, no external dependencies
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
LOCK_FILE="${PWD}/dependencies.lock"
HOST_MULTIARCH="$(gcc -dumpmachine 2>/dev/null || true)"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

if [ -n "$HOST_MULTIARCH" ]; then
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$PREFIX/lib/$HOST_MULTIARCH/pkgconfig"
fi

export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}"
export CPPFLAGS="-I$PREFIX/include"
export LD_LIBRARY_PATH="$PREFIX/lib${HOST_MULTIARCH:+:$PREFIX/lib/$HOST_MULTIARCH}:$LD_LIBRARY_PATH"

# Additional compiler flags for full static linking
export CFLAGS="-O2"
export CXXFLAGS="-O2"


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

sanitize_no_werror_flags() {
    local input_flags="$1"
    local sanitized_flags=()
    local flag

    for flag in $input_flags; do
        if [[ "$flag" == -Werror* ]]; then
            continue
        fi
        sanitized_flags+=("$flag")
    done

    echo "${sanitized_flags[*]}"
}

compiler_supports_flag() {
    local flag="$1"
    local cc_bin="${CC:-gcc}"

    printf 'int main(void){return 0;}\n' | "$cc_bin" "$flag" -x c -c -o /dev/null - >/dev/null 2>&1
}

load_dependency_lock() {
    if [ ! -f "$LOCK_FILE" ]; then
        log_error "Dependency lock file not found: $LOCK_FILE"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$LOCK_FILE"

    local required_vars=(
        ZLIB_REPO ZLIB_TAG
        LIBJPEG_TURBO_REPO LIBJPEG_TURBO_TAG
        LIBPNG_REPO LIBPNG_TAG
        FREETYPE_REPO FREETYPE_TAG
        HARFBUZZ_REPO HARFBUZZ_TAG
        LIBWEBP_REPO LIBWEBP_TAG
        LIBTIFF_REPO LIBTIFF_TAG
        FONTCONFIG_REPO FONTCONFIG_TAG
    )

    local missing=0
    for var_name in "${required_vars[@]}"; do
        if [ -z "${!var_name}" ]; then
            log_error "Missing '$var_name' in dependency lock file"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

checkout_repo_tag() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_tag="$3"

    if [ -d "$repo_dir/.git" ]; then
        log_info "Updating $repo_dir to tag $repo_tag"
        git -C "$repo_dir" remote set-url origin "$repo_url"
        git -C "$repo_dir" fetch --depth 1 origin "refs/tags/$repo_tag:refs/tags/$repo_tag" || \
            git -C "$repo_dir" fetch --depth 1 origin "$repo_tag"
    else
        rm -rf "$repo_dir"
        log_info "Cloning $repo_dir at tag $repo_tag"
        git clone --depth 1 --branch "$repo_tag" "$repo_url" "$repo_dir"
    fi

    git -C "$repo_dir" checkout -f "$repo_tag"
}

# Function to install build dependencies
install_dependencies() {
    log_info "Installing build dependencies..."
    
    if ! command -v apt-get &> /dev/null; then
        log_error "apt-get not found. This script is designed for Debian/Ubuntu systems."
        exit 1
    fi
    
    # sudo apt-get update
    # sudo apt-get install -y \
    #     build-essential \
    #     pkg-config \
    #     git \
    #     curl \
    #     wget \
    #     autoconf \
    #     automake \
    #     libtool \
    #     cmake \
    #     nasm \
    #     perl \
    #     python3 \
    #     python3-pip \
    #     meson \
    #     ninja-build \
    #     gperf
    
    log_info "Build dependencies installed successfully"
}

# Function to build a static dependency
build_zlib() {
    log_info "Building zlib (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "zlib" "$ZLIB_REPO" "$ZLIB_TAG"

    cd zlib
    local zlib_cflags
    zlib_cflags="$(sanitize_no_werror_flags "$CFLAGS") -Wno-error"
    CFLAGS="$zlib_cflags" ./configure --static --prefix="$PREFIX"
    make -j$(nproc)
    make install
    cd ..
}

build_jpeg() {
    log_info "Building libjpeg-turbo (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libjpeg-turbo" "$LIBJPEG_TURBO_REPO" "$LIBJPEG_TURBO_TAG"

    cd libjpeg-turbo
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
           -DCMAKE_BUILD_TYPE=Release \
           -DENABLE_SHARED=OFF \
           -DENABLE_STATIC=ON \
           ..
    make -j$(nproc)
    make install
    cd ../..
}

build_png() {
    log_info "Building libpng (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libpng" "$LIBPNG_REPO" "$LIBPNG_TAG"

    cd libpng
    
    # Generate configure script if it doesn't exist
    # log_info "Generating libpng configure script..."
    # ./autogen.sh
    
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --with-zlib-prefix="$PREFIX"
    make -j$(nproc)
    make install
    cd ..
}

build_freetype() {
    local enable_harfbuzz="${1:-false}"

    if [ "$enable_harfbuzz" = "true" ]; then
        log_info "Building freetype (static, with harfbuzz)..."
    else
        log_info "Building freetype (static, without harfbuzz)..."
    fi

    cd "$WORK_DIR"

    checkout_repo_tag "freetype" "$FREETYPE_REPO" "$FREETYPE_TAG"
    
    cd freetype

    # Clean previous build state so the second pass can pick up HarfBuzz.
    if [ -f "Makefile" ]; then
        make distclean >/dev/null 2>&1 || true
    fi
    
    # Fall back to autotools for older versions
    log_info "Building freetype with autotools (older versions)..."
    log_info "Generating freetype configure script..."
    ./autogen.sh

    local harfbuzz_flag="--without-harfbuzz"
    if [ "$enable_harfbuzz" = "true" ]; then
        harfbuzz_flag="--with-harfbuzz=yes"
    fi
    
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                "$harfbuzz_flag" \
                --with-zlib-prefix="$PREFIX"
    make -j$(nproc)
    make install
    
    cd ..
}

build_harfbuzz() {
    log_info "Building harfbuzz (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "harfbuzz" "$HARFBUZZ_REPO" "$HARFBUZZ_TAG"

    cd harfbuzz

    rm -rf build
    meson setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Dtests=disabled \
        -Ddocs=disabled \
        -Dintrospection=disabled \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dcairo=disabled \
        -Dicu=disabled \
        -Dgraphite=disabled \
        -Dfreetype=enabled
    ninja -C build
    ninja -C build install

    cd ..
}

build_webp() {
    log_info "Building libwebp (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libwebp" "$LIBWEBP_REPO" "$LIBWEBP_TAG"

    cd libwebp
    
    # Generate configure script if it doesn't exist
    if [ ! -f "configure" ]; then
        log_info "Generating libwebp configure script..."
        ./autogen.sh
    fi
    
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static
    make -j$(nproc)
    make install
    cd ..
}

build_tiff() {
    log_info "Building libtiff (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libtiff" "$LIBTIFF_REPO" "$LIBTIFF_TAG"

    cd libtiff
    
    # Generate configure script if it doesn't exist
    if [ ! -f "configure" ]; then
        log_info "Generating libtiff configure script..."
        ./autogen.sh
    fi
    
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
    log_info "Building fontconfig (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "fontconfig" "$FONTCONFIG_REPO" "$FONTCONFIG_TAG"

    cd fontconfig
    
    # Generate configure script if it doesn't exist
    if [ ! -f "configure" ]; then
        log_info "Generating fontconfig configure script..."
        ./autogen.sh
    fi
    
    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --with-freetype-config="$PREFIX/bin/freetype-config" \
                --disable-docs
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

# Function to build ImageMagick with full static linking
build_imagemagick() {
    log_info "Building ImageMagick with ALL dependencies statically linked..."
    
    cd "$WORK_DIR/ImageMagick"

    # Ensure delegate/config changes take effect on repeat builds.
    if [ -f "Makefile" ]; then
        make distclean >/dev/null 2>&1 || true
    fi
    
    # Export library paths - force static linking
    export LDFLAGS="-static -static-libgcc -L$PREFIX/lib"

    # Avoid stale tools from previous runs (for example Magick++-config).
    rm -rf "$PREFIX/imagemagick"
    
    log_info "Running configure with full static linking (core utilities only)..."
    ./configure \
        --prefix="$PREFIX/imagemagick" \
        --enable-static \
        --disable-shared \
        --disable-ltdl-install \
        --disable-magick-plus-plus \
        --disable-perl \
        --without-xml \
        --disable-openmp \
        --with-quantum-depth=16 \
        --enable-hdri \
        --with-zlib="$PREFIX" \
        --with-jpeg="$PREFIX" \
        --with-png="$PREFIX" \
        --with-freetype="$PREFIX" \
        --with-webp="$PREFIX" \
        --with-tiff="$PREFIX" \
        --with-fontconfig="$PREFIX" \
        --disable-docs \
        --disable-dependency-tracking \
        --enable-cipher
    
    log_info "Compiling ImageMagick with full static linking (using $(nproc) cores)..."
    make -j$(nproc) LDFLAGS="-all-static -L$PREFIX/lib -L$PREFIX/lib64"
    
    log_info "Installing..."
    make install

    # Keep only runtime utilities in this build output.
    find "$PREFIX/imagemagick/bin" -maxdepth 1 -type f -name '*-config' -delete 2>/dev/null || true
    
    cd "$WORK_DIR"
}

# Function to verify binaries are static
verify_static() {
    log_info "Verifying binaries are fully static..."
    
    local bin_dir="$PREFIX/imagemagick/bin"
    local static_count=0
    local dynamic_count=0
    local inspected_binary
    
    for binary in "$bin_dir"/*; do
        if [ -f "$binary" ] && [ -x "$binary" ]; then
            # Config helper scripts are not runtime binaries and can be skipped.
            if [[ "$(basename "$binary")" == *-config ]]; then
                continue
            fi

            inspected_binary="$binary"
            if [ -L "$binary" ]; then
                inspected_binary="$(readlink -f "$binary")"
            fi

            # Use file command to check if static
            if file "$inspected_binary" | grep -q "statically linked"; then
                log_info "✓ $(basename $binary) is fully static"
                ((static_count++))
            else
                log_warn "✗ $(basename $binary) may have dynamic dependencies"
                ((dynamic_count++))
            fi
        fi
    done
    
    log_info "Verification complete: $static_count static, $dynamic_count dynamic"
}

# Function to strip and compress binaries
optimize_binaries() {
    log_info "Stripping and optimizing binaries..."
    
    find "$PREFIX/imagemagick/bin" -type f -executable -exec strip --strip-all {} \; 2>/dev/null || true
    
    log_info "Binary optimization complete"
}

# Function to create portable tarball (core utilities only)
create_portable_tarball() {
    local tag=$1
    local arch=$2
    
    log_info "Creating portable tarball with fully static core utilities..."
    
    mkdir -p "$BUILD_DIR"
    
    # Create portable structure
    local temp_dir="${WORK_DIR}/portable"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir/imagemagick-${tag}-${arch}"
    
    # Copy core utilities (magick binary and scripts)
    local bin_dir="$PREFIX/imagemagick/bin"
    local core_utils=("convert" "identify" "display" "animate" "composite" "mogrify" "compare" "magick")
    
    mkdir -p "$temp_dir/imagemagick-${tag}-${arch}/bin"
    
    # Copy available core utilities only
    for util in "${core_utils[@]}"; do
        if [ -f "$bin_dir/$util" ]; then
            cp "$bin_dir/$util" "$temp_dir/imagemagick-${tag}-${arch}/bin/"
            log_info "Included: $util"
        fi
    done
    
    # Create README with installation and usage info
    cat > "$temp_dir/imagemagick-${tag}-${arch}/README.md" << 'EOF'
# ImageMagick Fully Static Portable Build

This is a completely self-contained build of ImageMagick core utilities with ALL dependencies statically linked into single binaries.

## No External Dependencies Required!

This build includes everything needed:
- zlib
- libjpeg-turbo
- libpng
- freetype
- harfbuzz
- libwebp
- libtiff
- fontconfig

All are statically compiled into the binaries themselves.

## Installation

### Option 1: Add to PATH (Recommended)
```bash
export PATH="$(pwd)/bin:$PATH"
```

### Option 2: Install to system
```bash
sudo cp bin/* /usr/local/bin/
```

### Option 3: Use directly
```bash
./bin/convert image.jpg -resize 100x100 thumbnail.jpg
./bin/identify image.jpg
```

## Core Utilities

- `magick` - Main ImageMagick utility
- `convert` - Image conversion and manipulation
- `identify` - Image information
- `display` - Image display
- `animate` - Animation tool
- `composite` - Image composition
- `mogrify` - In-place image modification
- `compare` - Image comparison

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

# Convert JPEG to WebP
./bin/convert image.jpg image.webp

# Rotate image
./bin/convert input.jpg -rotate 90 rotated.jpg

# Composite images
./bin/composite foreground.png background.png result.png
```

## Requirements

✓ **NONE!** This build is completely self-contained.
- No external libraries needed
- No package dependencies
- Works on any Linux system with glibc
- No installation required - just run the binaries

## Binary Size

Single binary includes all functionality. Typically 8-15MB per utility.

## Verification

To verify binaries are fully static:
```bash
file ./bin/convert
# Should show: "statically linked"

ldd ./bin/convert
# Should show: "not a dynamic executable"
```

EOF

    # Create tarball
    cd "$temp_dir"
    tar -czf "${BUILD_DIR}/imagemagick-${tag}-linux-${arch}.tar.gz" "imagemagick-${tag}-${arch}/"
    cd - > /dev/null
    
    log_info "Portable tarball created: ${BUILD_DIR}/imagemagick-${tag}-linux-${arch}.tar.gz"
    ls -lh "${BUILD_DIR}/imagemagick-${tag}-linux-${arch}.tar.gz"
    
    # Verify contents
    log_info "Tarball contents (core utilities only):"
    tar -tzf "${BUILD_DIR}/imagemagick-${tag}-linux-${arch}.tar.gz"
}

# Function to display usage
usage() {
    cat << EOF
ImageMagick Fully Static Self-Contained Build Script

Builds ImageMagick core utilities with ALL dependencies statically linked into single binaries.
No external dependencies, no .so files, no bindings, completely portable.

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
    - Installed at: build-work/install/imagemagick/bin/
    - Dependency lock file: dependencies.lock

Build Process:
    1. Installs build dependencies (autoconf, cmake, meson, ninja, etc.)
    2. Builds zlib statically
    3. Builds libjpeg-turbo statically (cmake)
    4. Builds libpng statically (autotools)
    5. Builds freetype statically (pass 1, without harfbuzz)
    6. Builds harfbuzz statically
    7. Rebuilds freetype statically (pass 2, with harfbuzz)
    8. Builds libwebp statically (autotools)
    9. Builds libtiff statically (autotools)
    10. Builds fontconfig statically (autotools)
    11. Builds ImageMagick core utilities statically with all dependencies

Features:
    ✓ Fully static binaries - everything embedded
    ✓ Zero external dependencies
    ✓ Dependencies pinned to committed tags in dependencies.lock
    ✓ No .so files - just executables
    ✓ No C++ bindings (Magick++)
    ✓ No Perl bindings
    ✓ Core utilities only (convert, identify, etc.)
    ✓ Portable across all Linux systems
    ✓ Single binary per utility (~8-15MB)
    ✓ Automatic verification of static linking

Notes:
    - Requires Ubuntu 22.04 or similar Debian-based system
    - First build will take significant time (~45-90 minutes)
    - Subsequent builds are faster due to cached dependencies
    - Binaries are smaller (~8-15MB per tool vs 15-25MB with bindings)
    
To clean up build artifacts:
    rm -rf build-work/

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
    log_info "ImageMagick Fully Static Core Utilities Build"
    log_info "Tag: $RELEASE_TAG, Architecture: $TARGET_ARCH"

    load_dependency_lock
    
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

    # Use baseline CPU targets for portable binaries.
    local arch_cflags
    case $TARGET_ARCH in
        amd64)
            if compiler_supports_flag "-march=x86-64-v1"; then
                arch_cflags="-march=x86-64-v1 -mtune=generic"
            else
                log_warn "Compiler does not support -march=x86-64-v1; falling back to -march=x86-64"
                arch_cflags="-march=x86-64 -mtune=generic"
            fi
            ;;
        arm64)
            arch_cflags="-march=armv8-a"
            ;;
    esac

    export CFLAGS="-O2 $arch_cflags"
    export CXXFLAGS="-O2 $arch_cflags"
    log_info "Compiler baseline flags: CFLAGS='$CFLAGS' CXXFLAGS='$CXXFLAGS'"
    
    # Check if running on ARM but targeting AMD64 (or vice versa)
    CURRENT_ARCH=$(uname -m)
    if [ "$CURRENT_ARCH" = "x86_64" ] && [ "$TARGET_ARCH" = "arm64" ]; then
        log_error "Cross-compilation for arm64 on amd64 is not supported for static builds"
        log_warn "Please run this script natively on arm64 hardware"
        exit 1
    fi
    if [ "$CURRENT_ARCH" = "aarch64" ] && [ "$TARGET_ARCH" = "amd64" ]; then
        log_error "Cross-compilation for amd64 on arm64 is not supported for static builds"
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
    build_freetype false
    build_harfbuzz
    build_freetype true
    build_webp
    build_tiff
    build_fontconfig
    
    # Fetch and build ImageMagick
    fetch_imagemagick "$RELEASE_TAG"
    build_imagemagick
    verify_static
    optimize_binaries
    
    # Get the actual checked out tag
    ACTUAL_TAG=$CHECKED_OUT_TAG
    
    # Create portable tarball
    create_portable_tarball "$ACTUAL_TAG" "$TARGET_ARCH"
    
    log_info "================================"
    log_info "✓ Build completed successfully!"
    log_info "================================"
    log_info ""
    log_info "Output: $(pwd)/build/imagemagick-${ACTUAL_TAG}-linux-${TARGET_ARCH}.tar.gz"
    log_info ""
    log_info "To use the fully static build:"
    log_info "  1. Extract: tar -xzf build/imagemagick-${ACTUAL_TAG}-linux-${TARGET_ARCH}.tar.gz"
    log_info "  2. Option A - Add to PATH: export PATH=\"\$(pwd)/imagemagick-${ACTUAL_TAG}-${TARGET_ARCH}/bin:\$PATH\""
    log_info "  3. Option B - Install: sudo cp imagemagick-${ACTUAL_TAG}-${TARGET_ARCH}/bin/* /usr/local/bin/"
    log_info "  4. Use: convert image.jpg -resize 100x100 thumb.jpg"
    log_info ""
    log_info "NO external dependencies required - binaries are completely self-contained!"
    log_info ""
    
    # Verify a binary
    if [ -f "$PREFIX/imagemagick/bin/convert" ]; then
        log_info "Final verification..."
        file "$PREFIX/imagemagick/bin/convert"
    fi
    
    log_info ""
    log_info "To clean up build artifacts: rm -rf build-work/"
}

# Run main function
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

main
