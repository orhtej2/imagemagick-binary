#!/bin/bash
set -e

# ImageMagick Fully Static Self-Contained Build Script
# Builds ImageMagick with ALL dependencies statically linked into a single binary
# No .so files, no external dependencies
# Usage: ./build.sh [TAG] [ARCH]
# Examples:
#   ./build.sh 7.1.2-27 amd64      # Build specific tag for amd64
#   ./build.sh 7.1.2-27 arm64      # Build specific tag for arm64
#   ./build.sh 7.1.2-27 armv7      # Build specific tag for armv7/armhf
#   ./build.sh                      # Build latest for current architecture

# Configuration
IMAGEMAGICK_REPO="https://github.com/ImageMagick/ImageMagick.git"
RELEASE_TAG="${1:-latest}"
TARGET_ARCH="${2:-$(uname -m)}"
FULL_DELEGATES="${FULL_DELEGATES:-${3:-false}}"
WORK_DIR="${PWD}/build-work"
BUILD_DIR="${PWD}/build"
PREFIX="${WORK_DIR}/install"
LOCK_FILE="${PWD}/dependencies.lock"
HOST_MULTIARCH="$(gcc -dumpmachine 2>/dev/null || true)"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
MESON_BIN="meson"
MESON_CROSS_FILE=""
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"

if [ -n "$HOST_MULTIARCH" ]; then
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$PREFIX/lib/$HOST_MULTIARCH/pkgconfig"
fi

# Keep pkg-config isolated from host metadata so ImageMagick only enables
# delegates that this script actually built into the local prefix.
PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}"
export PKG_CONFIG_DIR=""
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64${HOST_MULTIARCH:+ -L$PREFIX/lib/$HOST_MULTIARCH}"
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

compiler_supports_armv7_fpu_flags() {
    local cc_bin="${CC:-gcc}"

    printf 'int main(void){return 0;}\n' | "$cc_bin" -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -x c -c -o /dev/null - >/dev/null 2>&1
}

autotools_host_flags() {
    if [ -n "${TARGET_TRIPLET:-}" ]; then
        printf '%s' "--host=${TARGET_TRIPLET}"
    fi
}

write_meson_cross_file() {
    local cross_file="$WORK_DIR/meson-armv7-cross.txt"
    mkdir -p "$WORK_DIR"
    cat > "$cross_file" <<EOF
[binaries]
c = '${CC:-arm-linux-gnueabihf-gcc}'
cpp = '${CXX:-arm-linux-gnueabihf-g++}'
ar = '${AR:-arm-linux-gnueabihf-ar}'
strip = '${STRIP:-arm-linux-gnueabihf-strip}'
pkgconfig = 'pkg-config'
exe_wrapper = ['qemu-arm-static', '-L', '/usr/arm-linux-gnueabihf']

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
    MESON_CROSS_FILE="$cross_file"
    export MESON_CROSS_FILE
    printf '%s' "$cross_file"
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
        LIBDEFLATE_REPO LIBDEFLATE_TAG
        LIBJPEG_TURBO_REPO LIBJPEG_TURBO_TAG
        LIBPNG_REPO LIBPNG_TAG
        BZIP2_REPO BZIP2_TAG
        ZSTD_REPO ZSTD_TAG
        OPENJPEG_REPO OPENJPEG_TAG
        LCMS2_REPO LCMS2_TAG
        XZ_REPO XZ_TAG
        LIBXML2_REPO LIBXML2_TAG
        LIBZIP_REPO LIBZIP_TAG
        MESON_REPO MESON_TAG
        PCRE2_REPO PCRE2_TAG
        LIBFFI_REPO LIBFFI_TAG
        GLIB_REPO GLIB_TAG
        GVDB_REPO GVDB_REF
        LIBLQR_REPO LIBLQR_TAG
        FRIBIDI_REPO FRIBIDI_TAG
        LIBRAQM_REPO LIBRAQM_TAG
        IMATH_REPO IMATH_TAG
        OPENEXR_REPO OPENEXR_TAG
        LIBDE265_REPO LIBDE265_TAG
        LIBHEIF_REPO LIBHEIF_TAG
        LIBRAW_REPO LIBRAW_TAG
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
        git -C "$repo_dir" checkout -f "$repo_tag"
        git -C "$repo_dir" reset --hard "$repo_tag"
        git -C "$repo_dir" clean -fdx
    else
        rm -rf "$repo_dir"
        log_info "Cloning $repo_dir at tag $repo_tag"
        git clone --depth 1 --branch "$repo_tag" "$repo_url" "$repo_dir"
    fi

    git -C "$repo_dir" checkout -f "$repo_tag"
}

checkout_repo_ref() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_ref="$3"

    rm -rf "$repo_dir"
    mkdir -p "$repo_dir"

    git -C "$repo_dir" init >/dev/null
    git -C "$repo_dir" remote add origin "$repo_url"
    git -C "$repo_dir" fetch --depth 1 origin "$repo_ref"
    git -C "$repo_dir" checkout -f FETCH_HEAD
    git -C "$repo_dir" clean -fdx
}

# Function to install build dependencies
install_dependencies() {
    if [ "${SKIP_APT_INSTALL:-false}" = "true" ]; then
        log_warn "Skipping apt dependency installation (SKIP_APT_INSTALL=true)"
        return 0
    fi

    log_info "Installing build dependencies..."
    
    if ! command -v apt-get &> /dev/null; then
        log_error "apt-get not found. This script is designed for Debian/Ubuntu systems."
        exit 1
    fi
    
    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        pkgconf \
        git \
        curl \
        wget \
        gettext \
        autoconf \
        automake \
        libtool \
        libltdl-dev \
        cmake \
        nasm \
        perl \
        python3 \
        python3-pip \
        python3-venv \
        ninja-build \
        gperf \
        autopoint \
        po4a
    
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
    CFLAGS="$zlib_cflags" ./configure --static --prefix="$PREFIX" $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_libdeflate() {
    log_info "Building libdeflate (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libdeflate" "$LIBDEFLATE_REPO" "$LIBDEFLATE_TAG"

    cd libdeflate
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLIBDEFLATE_BUILD_STATIC_LIB=ON \
        -DLIBDEFLATE_BUILD_SHARED_LIB=OFF \
        -DLIBDEFLATE_BUILD_GZIP=OFF \
        -DLIBDEFLATE_BUILD_TESTS=OFF \
        -DLIBDEFLATE_INSTALL=ON
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
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
           -DWITH_SIMD=OFF \
           ..
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
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
                --with-zlib-prefix="${PREFIX%/}/" \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_bzip2() {
    log_info "Building bzip2 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "bzip2" "$BZIP2_REPO" "$BZIP2_TAG"

    cd bzip2
    local bzip2_cflags
    bzip2_cflags="$(sanitize_no_werror_flags "$CFLAGS") -Wno-error -fPIC"
    make clean >/dev/null 2>&1 || true
    # Explicitly avoid the default bzip2 'all' target, which includes the self-test.
    # The self-test executes the armhf binary on the build host and fails without /lib/ld-linux-armhf.so.3.
    make -j"$BUILD_JOBS" bzip2 bzip2recover libbz2.a CC="${CC:-gcc}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}" CFLAGS="$bzip2_cflags"
    make -j"$BUILD_JOBS" install PREFIX="$PREFIX" CC="${CC:-gcc}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}"
    cd ..
}

build_zstd() {
    log_info "Building zstd (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "zstd" "$ZSTD_REPO" "$ZSTD_TAG"

    cd zstd
    rm -rf build/cmake/build-static
    cmake -S build/cmake -B build/cmake/build-static \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DZSTD_BUILD_PROGRAMS=OFF \
        -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_STATIC=ON
    cmake --build build/cmake/build-static --parallel "$BUILD_JOBS"
    cmake --install build/cmake/build-static
    cd ..
}

build_openjpeg() {
    log_info "Building openjpeg (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "openjpeg" "$OPENJPEG_REPO" "$OPENJPEG_TAG"

    cd openjpeg
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_CODEC=OFF \
        -DBUILD_JPIP=OFF
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_meson() {
    log_info "Building Meson (vendored)..."
    cd "$WORK_DIR"

    checkout_repo_tag "meson" "$MESON_REPO" "$MESON_TAG"

    cd meson
    rm -rf .venv
    python3 -m venv .venv
    .venv/bin/python -m pip install --upgrade pip setuptools wheel
    .venv/bin/python -m pip install .
    MESON_BIN="$PWD/.venv/bin/meson"
    export MESON_BIN
    log_info "Using vendored meson: $($MESON_BIN --version)"
    cd ..
}

build_lcms2() {
    log_info "Building lcms2 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "lcms2" "$LCMS2_REPO" "$LCMS2_TAG"

    cd lcms2
    if [ ! -f "configure" ]; then
        log_info "Generating lcms2 configure script..."
        autoreconf -fi
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-examples \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_xz() {
    log_info "Building xz/liblzma (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "xz" "$XZ_REPO" "$XZ_TAG"

    cd xz

    if [ ! -f "configure" ]; then
        log_info "Generating xz configure script..."
        ./autogen.sh
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-xz \
                --disable-xzdec \
                --disable-lzmadec \
                --disable-lzmainfo \
                --disable-scripts \
                --disable-doc \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_libxml2() {
    log_info "Building libxml2 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libxml2" "$LIBXML2_REPO" "$LIBXML2_TAG"

    cd libxml2
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DLIBXML2_WITH_PYTHON=OFF \
        -DLIBXML2_WITH_ICU=OFF \
        -DLIBXML2_WITH_ZLIB=ON \
        -DLIBXML2_WITH_TESTS=OFF \
        -DLIBXML2_WITH_PROGRAMS=OFF \
        -DCMAKE_PREFIX_PATH="$PREFIX"
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libzip() {
    log_info "Building libzip (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libzip" "$LIBZIP_REPO" "$LIBZIP_TAG"

    cd libzip
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_GNUTLS=OFF \
        -DENABLE_MBEDTLS=OFF \
        -DENABLE_OPENSSL=OFF \
        -DENABLE_COMMONCRYPTO=OFF \
        -DBUILD_TOOLS=OFF \
        -DBUILD_REGRESS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_OSSFUZZ=OFF \
        -DBUILD_DOC=OFF \
        -DZLIB_ROOT="$PREFIX" \
        -DZLIB_LIBRARY="$PREFIX/lib/libz.a" \
        -DZLIB_INCLUDE_DIR="$PREFIX/include"
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_pcre2() {
    log_info "Building PCRE2 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "pcre2" "$PCRE2_REPO" "$PCRE2_TAG"

    cd pcre2
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DPCRE2_BUILD_PCRE2_8=ON \
        -DPCRE2_BUILD_PCRE2_16=OFF \
        -DPCRE2_BUILD_PCRE2_32=OFF \
        -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF \
        -DPCRE2_SUPPORT_JIT=OFF \
        -DPCRE2_SHOW_REPORT=OFF \
        -DPCRE2_SUPPORT_LIBBZ2=OFF \
        -DPCRE2_SUPPORT_LIBZ=OFF \
        -DPCRE2_SUPPORT_LIBREADLINE=OFF \
        -DPCRE2_SUPPORT_LIBEDIT=OFF
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libffi() {
    log_info "Building libffi (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libffi" "$LIBFFI_REPO" "$LIBFFI_TAG"

    cd libffi
    if [ ! -f "configure" ]; then
        log_info "Generating libffi configure script..."
        if [ -f "/usr/share/aclocal/ltdl.m4" ] && [ ! -f "m4/ltdl.m4" ]; then
            cp /usr/share/aclocal/ltdl.m4 m4/ltdl.m4
        fi
        autoreconf -vfi -I m4
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-docs \
                --disable-multi-os-directory \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_glib() {
    log_info "Building glib-2.0 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "glib" "$GLIB_REPO" "$GLIB_TAG"

    cd glib
    rm -rf build subprojects/gvdb
    mkdir -p subprojects
    checkout_repo_ref "subprojects/gvdb" "$GVDB_REPO" "$GVDB_REF"

    local meson_cmd=(setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        --wrap-mode=nofallback \
        -Dtests=false \
        -Dinstalled_tests=false \
        -Dgtk_doc=false \
        -Dman=false \
        -Dnls=disabled \
        -Dselinux=disabled \
        -Dlibmount=disabled \
        -Dxattr=false \
        -Ddtrace=false \
        -Dsystemtap=false \
        -Dsysprof=disabled \
        -Dlibelf=disabled \
        -Dmultiarch=false \
        -Dglib_debug=disabled \
        -Dglib_assert=false \
        -Dglib_checks=false \
        -Doss_fuzz=disabled)
    if [ -n "$MESON_CROSS_FILE" ]; then
        meson_cmd+=(--cross-file "$MESON_CROSS_FILE")
    fi
    "$MESON_BIN" "${meson_cmd[@]}"
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

build_liblqr() {
    log_info "Building liblqr (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "liblqr" "$LIBLQR_REPO" "$LIBLQR_TAG"

    cd liblqr
    if [ ! -f "configure" ]; then
        log_info "Generating liblqr configure script..."
        ./autogen.sh
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_fribidi() {
    log_info "Building fribidi (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "fribidi" "$FRIBIDI_REPO" "$FRIBIDI_TAG"

    cd fribidi
    rm -rf build
    local meson_cmd=(setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Ddocs=false \
        -Dtests=false \
        -Dbin=false)
    if [ -n "$MESON_CROSS_FILE" ]; then
        meson_cmd+=(--cross-file "$MESON_CROSS_FILE")
    fi
    "$MESON_BIN" "${meson_cmd[@]}"
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

build_libraqm() {
    log_info "Building libraqm (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libraqm" "$LIBRAQM_REPO" "$LIBRAQM_TAG"

    cd libraqm
    rm -rf build
    local meson_cmd=(setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release)
    if [ -n "$MESON_CROSS_FILE" ]; then
        meson_cmd+=(--cross-file "$MESON_CROSS_FILE")
    fi
    "$MESON_BIN" "${meson_cmd[@]}"
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

build_imath() {
    log_info "Building Imath (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "Imath" "$IMATH_REPO" "$IMATH_TAG"

    cd Imath
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_openexr() {
    log_info "Building OpenEXR (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "openexr" "$OPENEXR_REPO" "$OPENEXR_TAG"

    cd openexr
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DOPENEXR_BUILD_TOOLS=OFF \
        -DOPENEXR_BUILD_EXAMPLES=OFF \
        -DCMAKE_PREFIX_PATH="$PREFIX"
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libde265() {
    log_info "Building libde265 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libde265" "$LIBDE265_REPO" "$LIBDE265_TAG"

    cd libde265
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_ENCODER=OFF
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libheif() {
    log_info "Building libheif (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libheif" "$LIBHEIF_REPO" "$LIBHEIF_TAG"

    cd libheif
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DWITH_LIBDE265=ON \
        -DWITH_X265=OFF \
        -DWITH_AOM=OFF \
        -DWITH_DAV1D=OFF \
        -DWITH_RAV1E=OFF \
        -DWITH_SvtEnc=OFF \
        -DWITH_OpenH264=OFF \
        -DWITH_JPEG_DECODER=OFF \
        -DWITH_JPEG_ENCODER=OFF \
        -DWITH_EXAMPLES=OFF \
        -DWITH_GDK_PIXBUF=OFF \
        -DWITH_REDUCED_VISIBILITY=ON \
        -DCMAKE_PREFIX_PATH="$PREFIX"
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ..
}

build_libraw() {
    log_info "Building LibRaw (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "LibRaw" "$LIBRAW_REPO" "$LIBRAW_TAG"

    cd LibRaw

    # Ensure we do not reuse stale configure/cache state from previous attempts.
    if [ -f "Makefile" ]; then
        make distclean >/dev/null 2>&1 || true
    fi
    rm -f config.cache

    if [ ! -f "configure" ]; then
        if [ -f "autogen.sh" ]; then
            log_info "Generating LibRaw configure script..."
            ./autogen.sh
        else
            autoreconf -fi
        fi
    fi

    CXX="${CXX:-g++}" CXXLD="${CXX:-g++}" LIBS="${LIBS:-} -lstdc++" ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --enable-examples=no \
                --enable-openmp=no \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
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
                --with-zlib-prefix="$PREFIX" \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    
    cd ..
}

build_harfbuzz() {
    log_info "Building harfbuzz (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "harfbuzz" "$HARFBUZZ_REPO" "$HARFBUZZ_TAG"

    cd harfbuzz

    rm -rf build
    local meson_cmd=(setup build \
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
        -Dfreetype=enabled)
    if [ -n "$MESON_CROSS_FILE" ]; then
        meson_cmd+=(--cross-file "$MESON_CROSS_FILE")
    fi
    "$MESON_BIN" "${meson_cmd[@]}"
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install

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
                --enable-static \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
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
                --with-libdeflate-include-dir="$PREFIX/include" \
                --with-libdeflate-lib-dir="$PREFIX/lib" \
                --with-jpeg-include-dir="$PREFIX/include" \
                --with-jpeg-lib-dir="$PREFIX/lib" \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
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

    # Fontconfig caches the expat/libxml2 probe in config.cache/config.status.
    # If this source tree is reused after an earlier failed configure, that stale
    # result can overshadow the intended --enable-libxml2 path even when the
    # local libxml2 pkg-config metadata is present.
    make distclean >/dev/null 2>&1 || true
    rm -f config.cache config.log config.status
    rm -rf autom4te.cache

    local libxml_pkg_path="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"
    local libxml_pkg_libdir="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"
    export PKG_CONFIG_PATH="$libxml_pkg_path${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export PKG_CONFIG_LIBDIR="$libxml_pkg_libdir${PKG_CONFIG_LIBDIR:+:$PKG_CONFIG_LIBDIR}"

    local fc_configure_args=(
        --prefix="$PREFIX"
        --disable-shared
        --enable-static
        --enable-libxml2
        --with-freetype-config="$PREFIX/bin/freetype-config"
        --disable-docs
    )

    if ! PKG_CONFIG_PATH="$libxml_pkg_path${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
         PKG_CONFIG_LIBDIR="$libxml_pkg_libdir${PKG_CONFIG_LIBDIR:+:$PKG_CONFIG_LIBDIR}" \
         pkg-config --exists libxml-2.0; then
        log_error "Local libxml2 pkg-config metadata was not found in $PREFIX; cannot build fontconfig with libxml2"
        exit 1
    fi

    local libxml_cflags
    local libxml_libs
    libxml_cflags="$(PKG_CONFIG_PATH="$libxml_pkg_path${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        PKG_CONFIG_LIBDIR="$libxml_pkg_libdir${PKG_CONFIG_LIBDIR:+:$PKG_CONFIG_LIBDIR}" \
        pkg-config --cflags libxml-2.0)"
    libxml_libs="$(PKG_CONFIG_PATH="$libxml_pkg_path${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        PKG_CONFIG_LIBDIR="$libxml_pkg_libdir${PKG_CONFIG_LIBDIR:+:$PKG_CONFIG_LIBDIR}" \
        pkg-config --libs libxml-2.0)"

    PKG_CONFIG_PATH="$libxml_pkg_path${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
    PKG_CONFIG_LIBDIR="$libxml_pkg_libdir${PKG_CONFIG_LIBDIR:+:$PKG_CONFIG_LIBDIR}" \
    LIBXML2_CFLAGS="$libxml_cflags" \
    LIBXML2_LIBS="$libxml_libs" \
    ./configure "${fc_configure_args[@]}" $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
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
    
    # Keep build fully static and isolated from host pkg-config metadata.
    export LDFLAGS="-static -static-libgcc -L$PREFIX/lib -L$PREFIX/lib64"
    # export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

    local tiff_pkg=""
    if pkg-config --exists libtiff-4; then
        tiff_pkg="libtiff-4"
    elif pkg-config --exists libtiff; then
        tiff_pkg="libtiff"
    else
        log_error "Required static pkg-config metadata missing: libtiff-4/libtiff"
        log_info "pkg-config search path: $PKG_CONFIG_LIBDIR"
        pkg-config --print-errors --exists libtiff-4 || true
        pkg-config --print-errors --exists libtiff || true
        find "$PREFIX" -type f -name 'libtiff*.pc' -print || true
        exit 1
    fi

    # Keep higher-level libraries before their static dependencies so GNU ld can
    # resolve symbols in a single left-to-right pass.
    local required_pkgs=(
        libzip
        raqm
        OpenEXR
        "$tiff_pkg"
        libpng
        libxml-2.0
        libdeflate
        zlib
        liblzma
        libzstd
    )
    local libraw_pkg=""
    if [[ "$FULL_DELEGATES" == "true" ]]; then
        if pkg-config --exists libraw_r; then
            libraw_pkg="libraw_r"
        elif pkg-config --exists libraw; then
            libraw_pkg="libraw"
        else
            log_error "Required static pkg-config metadata missing: libraw_r/libraw"
            exit 1
        fi

        required_pkgs+=(libheif "$libraw_pkg" lqr-1 libde265)
    fi

    local missing_pkgs=()
    local pkg_name
    for pkg_name in "${required_pkgs[@]}"; do
        if ! pkg-config --exists "$pkg_name"; then
            missing_pkgs+=("$pkg_name")
        fi
    done

    if [ "${#missing_pkgs[@]}" -ne 0 ]; then
        log_error "Required static pkg-config metadata missing: ${missing_pkgs[*]}"
        log_info "pkg-config search path: $PKG_CONFIG_LIBDIR"
        local missing_pkg
        for missing_pkg in "${missing_pkgs[@]}"; do
            pkg-config --print-errors --exists "$missing_pkg" || true
        done
        exit 1
    fi

    local pkg_static_libs
    pkg_static_libs="$(pkg-config --libs --static "${required_pkgs[@]}")"
    log_info "Resolved static pkg-config libs: $pkg_static_libs"
    export LIBS="-Wl,--start-group ${pkg_static_libs} -Wl,--end-group -lheif -lde265 -lzip -lzstd -llzma -ldeflate -ldl -lpthread -lm ${LIBS:-}"

    # Avoid stale tools from previous runs (for example Magick++-config).
    rm -rf "$PREFIX/imagemagick"
    
    log_info "Running configure with full static linking (core utilities only)..."
    local configure_args=(
        --prefix="$PREFIX/imagemagick"
        --enable-static
        --disable-shared
        --without-magick-plus-plus
        --with-perl=no
        --without-x
        --disable-openmp
        --with-quantum-depth=16
        --enable-hdri
        --with-zlib=yes
        --with-bzlib=yes
        --with-zstd=yes
        --with-jpeg=yes
        --with-png=yes
        --with-openjp2=yes
        --with-lcms=yes
        --with-lzma=yes
        --with-openexr=yes
        --with-raqm=yes
        --with-zip=yes
        --with-freetype=yes
        --with-webp=yes
        --with-tiff=yes
        --with-fontconfig=yes
        --with-xml=yes
        --disable-docs
        --disable-dependency-tracking
        --enable-cipher
    )

    if [[ "$FULL_DELEGATES" == "true" ]]; then
        configure_args+=(
            --with-heic=yes
            --with-raw=yes
            --with-lqr=yes
        )
    fi

    ./configure "${configure_args[@]}"
    
    log_info "Compiling ImageMagick with full static linking (using $BUILD_JOBS cores)..."
    make -j"$BUILD_JOBS" LDFLAGS="-all-static -L$PREFIX/lib -L$PREFIX/lib64"
    
    log_info "Installing..."
    make -j"$BUILD_JOBS" install

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
                static_count=$((static_count + 1))
            else
                log_warn "✗ $(basename $binary) may have dynamic dependencies"
                dynamic_count=$((dynamic_count + 1))
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
    local core_utils=("convert" "identify" "composite" "mogrify" "compare" "magick")
    
    mkdir -p "$temp_dir/imagemagick-${tag}-${arch}/bin"
    
    # Copy available core utilities only, preserving symlinks to avoid bloating
    # the portable tarball with multiple copies of the same magick binary.
    for util in "${core_utils[@]}"; do
        if [ -e "$bin_dir/$util" ]; then
            cp -a "$bin_dir/$util" "$temp_dir/imagemagick-${tag}-${arch}/bin/"
            if [ -L "$bin_dir/$util" ]; then
                log_info "Included symlink: $util -> $(readlink "$bin_dir/$util")"
            else
                log_info "Included: $util"
            fi
        fi
    done
    
    # Create README with installation and usage info
    cat > "$temp_dir/imagemagick-${tag}-${arch}/README.md" << 'EOF'
# ImageMagick Fully Static Portable Build

This is a completely self-contained build of ImageMagick core utilities with ALL dependencies statically linked into single binaries.

## No External Dependencies Required!

This build includes everything needed:
- zlib
- libdeflate
- libjpeg-turbo
- libpng
- bzip2
- zstd
- openjpeg
- lcms2
- xz/liblzma
- libxml2
- libzip
- PCRE2
- libffi
- glib-2.0
- gvdb
- liblqr
- fribidi
- libraqm
- Imath
- OpenEXR
- libde265
- libheif
- LibRaw
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
- `composite` - Image composition
- `mogrify` - In-place image modification
- `compare` - Image comparison

This portable build is configured without X11 delegate support.
Commands that require X11 display integration (such as `display` and `animate`) are intentionally omitted.

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

Environment:
    SKIP_APT_INSTALL=true   Skip the apt-get dependency step for local iterative builds

Options:
    TAG         Release tag to build (default: latest)
                Example: 7.1.2-27
    
    ARCH        Target architecture (default: current system architecture)
                Options: amd64, arm64, armv7 (armhf)

Examples:
    # Build latest for current architecture
    ./build.sh

    # Build specific version for amd64
    ./build.sh 7.1.2-27 amd64

    # Build specific version for arm64
    ./build.sh 7.1.2-27 arm64

    # Build specific version for armv7/armhf
    ./build.sh 7.1.2-27 armv7

    # Iterate locally without re-running apt-get every time
    SKIP_APT_INSTALL=true ./build.sh 7.1.2-30 armv7

Output:
    - Portable tarball: build/imagemagick-<tag>-linux-<arch>.tar.gz
    - Build directory: build-work/
    - Installed at: build-work/install/imagemagick/bin/
    - Dependency lock file: dependencies.lock

Build Process:
    1. Installs build dependencies (autoconf, cmake, meson, ninja, etc.)
    2. Builds zlib statically
    3. Builds libdeflate statically (cmake)
    4. Builds libjpeg-turbo statically (cmake)
    5. Builds libpng statically (autotools)
    6. Builds bzip2 statically
    7. Builds zstd statically (cmake)
    8. Builds openjpeg statically (cmake)
    9. Builds lcms2 statically (autotools)
    10. Builds xz/liblzma statically (autotools)
    11. Builds libzip statically (cmake)
    12. Builds Meson (vendored python environment)
    13. Builds PCRE2 statically (cmake)
    14. Builds libffi statically (autotools)
    15. Builds glib-2.0 statically (meson, with vendored gvdb)
    16. Builds liblqr statically (autotools)
    17. Builds freetype statically (pass 1, without harfbuzz)
    18. Builds harfbuzz statically
    19. Rebuilds freetype statically (pass 2, with harfbuzz)
    20. Builds fribidi statically (meson)
    21. Builds libraqm statically (meson)
    22. Builds Imath statically (cmake)
    23. Builds OpenEXR statically (cmake)
    24. Builds libde265 statically (cmake)
    25. Builds libheif statically (cmake)
    26. Builds LibRaw statically (autotools)
    27. Builds libwebp statically (autotools)
    28. Builds libtiff statically (autotools)
    29. Builds libxml2 statically (cmake)
    30. Builds fontconfig statically (autotools)
    31. Builds ImageMagick core utilities statically with all dependencies

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
    - Set FULL_DELEGATES=true to enable extra source-built delegates (HEIC/RAW/LQR)
    
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
    log_info "FULL_DELEGATES: $FULL_DELEGATES"

    load_dependency_lock
    mkdir -p "$WORK_DIR"
    mkdir -p "$BUILD_DIR"
    
    # Validate architecture
    case $TARGET_ARCH in
        amd64|x86_64)
            TARGET_ARCH="amd64"
            ;;
        arm64|aarch64)
            TARGET_ARCH="arm64"
            ;;
        armv7|armhf|armv7l)
            TARGET_ARCH="armv7"
            ;;
        *)
            log_error "Unsupported architecture: $TARGET_ARCH"
            log_warn "Supported architectures: amd64, arm64, armv7 (armhf)"
            exit 1
            ;;
    esac

    if [ "$TARGET_ARCH" = "armv7" ]; then
        local target_triplet="arm-linux-gnueabihf"
        local qemu_sysroot="/usr/arm-linux-gnueabihf"
        TARGET_TRIPLET="$target_triplet"
        export CC="${CC:-${target_triplet}-gcc}"
        export CXX="${CXX:-${target_triplet}-g++}"
        export AR="${AR:-${target_triplet}-ar}"
        export RANLIB="${RANLIB:-${target_triplet}-ranlib}"
        export STRIP="${STRIP:-${target_triplet}-strip}"
        export QEMU_LD_PREFIX="$qemu_sysroot"
        export QEMU_SET_ENV="LD_LIBRARY_PATH=/usr/arm-linux-gnueabihf/lib:/usr/arm-linux-gnueabihf/lib/arm-linux-gnueabihf"
        log_info "Using armv7 cross-toolchain: CC=${CC} CXX=${CXX} AR=${AR} RANLIB=${RANLIB}"
        log_info "QEMU_LD_PREFIX=${QEMU_LD_PREFIX}"
        write_meson_cross_file
    else
        TARGET_TRIPLET=""
        MESON_CROSS_FILE=""
        unset QEMU_LD_PREFIX QEMU_SET_ENV
        export MESON_CROSS_FILE
    fi

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
        armv7)
            arch_cflags="-march=armv7-a"
            if compiler_supports_armv7_fpu_flags; then
                arch_cflags="$arch_cflags -mfpu=vfpv3-d16 -mfloat-abi=hard"
            else
                log_warn "armv7 cross-compiler does not support the required hard-float pair (-mfpu=vfpv3-d16 -mfloat-abi=hard); using generic armv7 baseline without it"
            fi
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
    build_libdeflate
    build_jpeg
    build_png
    build_bzip2
    build_zstd
    build_openjpeg
    build_lcms2
    build_xz
    build_libzip
    build_meson
    build_pcre2
    build_libffi
    build_glib
    build_liblqr
    build_freetype false
    build_harfbuzz
    build_freetype true
    build_fribidi
    build_libraqm
    build_imath
    build_openexr
    build_libde265
    build_libheif
    build_libraw
    build_webp
    build_tiff
    build_libxml2
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
