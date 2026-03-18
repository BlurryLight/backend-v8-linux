#!/bin/bash

set -e

VERSION=11.8.172
NEW_WRAP=""
ENABLE_MAGLEV=false
DO_CLEAN=true
BUILD_TYPE=Release
# GITHUB_WORKSPACE=/home/panda/code/backend-v8-linux
GITHUB_WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $0 [--maglev] [--no-maglev] [--clean] [--no-clean] [--build-type Debug|Release]

Options:
  --maglev            Enable Maglev compilation.
  --no-maglev         Disable Maglev compilation.
  --clean             Clean ninja outputs before build.
  --no-clean          Keep ninja outputs for incremental build.
  --build-type TYPE   Build type: Debug or Release. Default: Release.
  -h, --help          Show this help message.
EOF
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ensure_apt_packages() {
    local missing_packages=()
    local package

    for package in "$@"; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done

    if [ ${#missing_packages[@]} -eq 0 ]; then
        return 0
    fi

    echo "Missing apt packages: ${missing_packages[*]}"

    if [ "$(id -u)" -eq 0 ]; then
        apt-get install -y "${missing_packages[@]}"
        return 0
    fi

    if have_cmd sudo && sudo -n true 2>/dev/null; then
        sudo apt-get install -y "${missing_packages[@]}"
        return 0
    fi

    echo "Please install the missing packages manually, or run with passwordless sudo."
    exit 1
}

ensure_python_package() {
    local import_name="$1"
    local package_name="$2"
    local apt_package="$3"

    if python3 -c "import ${import_name}" >/dev/null 2>&1; then
        return 0
    fi

    if [ "$package_name" = "virtualenv" ] && python3 -m venv -h >/dev/null 2>&1; then
        echo "virtualenv is unavailable, using stdlib venv instead."
        return 0
    fi

    if [ -n "$apt_package" ]; then
        echo "Missing Python package: ${package_name}, trying apt package ${apt_package}"
        ensure_apt_packages "$apt_package"
    else
        echo "Missing Python package: ${package_name}"
        echo "Please install it manually."
        exit 1
    fi

    if ! python3 -c "import ${import_name}" >/dev/null 2>&1; then
        echo "Python package ${package_name} is still unavailable after installation."
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --maglev)
            ENABLE_MAGLEV=true
            ;;
        --no-maglev)
            ENABLE_MAGLEV=false
            ;;
        --clean)
            DO_CLEAN=true
            ;;
        --no-clean)
            DO_CLEAN=false
            ;;
        --build-type)
            shift
            if [ -z "$1" ]; then
                echo "Missing value for --build-type"
                usage
                exit 1
            fi
            BUILD_TYPE="$1"
            ;;
        --build-type=*)
            BUILD_TYPE="${1#*=}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

case "$BUILD_TYPE" in
    Debug|debug)
        BUILD_TYPE=Debug
        IS_DEBUG=true
        BUILD_DIR="out.gn/x64.debug"
        BUILD_TYPE_LOWER="debug"
        STRIP_DEBUG_INFO=false
        SYMBOL_LEVEL=2
        V8_OPTIMIZED_DEBUG=false
        USE_DEBUG_FISSION=false
        ;;
    Release|release)
        BUILD_TYPE=Release
        IS_DEBUG=false
        BUILD_DIR="out.gn/x64.release"
        BUILD_TYPE_LOWER="release"
        STRIP_DEBUG_INFO=true
        SYMBOL_LEVEL=0
        V8_OPTIMIZED_DEBUG=true
        USE_DEBUG_FISSION=true
        ;;
    *)
        echo "Invalid build type: $BUILD_TYPE"
        usage
        exit 1
        ;;
esac

if [ "$ENABLE_MAGLEV" = true ]; then
    MAGLEV_ARG=true
    MAGLEV_SUFFIX="_maglev"
else
    MAGLEV_ARG=false
    MAGLEV_SUFFIX=""
fi

OUTPUT_BASE="output/${BUILD_TYPE}/v8"
TAR_NAME="output_v8_${BUILD_TYPE_LOWER}${MAGLEV_SUFFIX}.tar.gz"

ensure_apt_packages \
    pkg-config \
    git \
    subversion \
    curl \
    wget \
    build-essential \
    python3 \
    ninja-build \
    xz-utils \
    zip

ensure_python_package virtualenv virtualenv python3-virtualenv

cd ~
echo "=====[ Getting Depot Tools ]====="	
if [ ! -d "$HOME/depot_tools/.git" ]; then
    git clone -q https://chromium.googlesource.com/chromium/tools/depot_tools.git
else
    echo "Reusing existing depot_tools at $HOME/depot_tools"
fi
export DEPOT_TOOLS_UPDATE=0
export PATH=$(pwd)/depot_tools:$PATH
~/depot_tools/ensure_bootstrap


mkdir -p v8
cd v8

echo "=====[ Fetching V8 ]====="
if [ ! -d "$HOME/v8/v8/.git" ]; then
    fetch v8
else
    echo "Reusing existing V8 checkout at $HOME/v8/v8"
fi

if ! grep -q "target_os = \\['linux'\\]" .gclient 2>/dev/null; then
    echo "target_os = ['linux']" >> .gclient
fi

cd ~/v8/v8
git checkout refs/tags/$VERSION
gclient sync

if grep -q "#include <uchar.h>" src/inspector/string-16.h src/inspector/v8-string-conversions.h; then
    node $GITHUB_WORKSPACE/node-script/do-gitpatch.js -p $GITHUB_WORKSPACE/patches/remove_uchar_include_v11.8.172.patch
else
    echo "remove_uchar_include patch already applied, skipping."
fi
# node $GITHUB_WORKSPACE/node-script/do-gitpatch.js -p $GITHUB_WORKSPACE/patches/enable_wee8_v11.8.172.patch

CXX_SETTING="use_custom_libcxx=false"

if [ "$NEW_WRAP" == "with_new_wrap" ]; then 
  echo "=====[ wrap new delete ]====="
  ensure_apt_packages llvm
  CXX_SETTING="use_custom_libcxx=true"
fi

echo "=====[ add ArrayBuffer_New_Without_Stl ]====="
node $GITHUB_WORKSPACE/node-script/add_arraybuffer_new_without_stl.js . $VERSION $NEW_WRAP

node $GITHUB_WORKSPACE/node-script/patchs.js . $VERSION $NEW_WRAP

echo "=====[ Building V8 ]====="

gn gen "$BUILD_DIR" --args="is_debug=$IS_DEBUG v8_optimized_debug=$V8_OPTIMIZED_DEBUG use_debug_fission=$USE_DEBUG_FISSION v8_enable_i18n_support=false v8_use_snapshot=true v8_use_external_startup_data=false is_component_build=true strip_debug_info=$STRIP_DEBUG_INFO symbol_level=$SYMBOL_LEVEL v8_enable_pointer_compression=false v8_enable_sandbox=false $CXX_SETTING is_clang=true v8_enable_maglev=$MAGLEV_ARG v8_enable_webassembly=false"

echo "=====[ Generating compile_commands.json ]====="
ninja -C "$BUILD_DIR" -t compdb cc cxx objc objcxx > "$BUILD_DIR/compile_commands.json"
ln -sfn "$BUILD_DIR/compile_commands.json" compile_commands.json

if [ "$DO_CLEAN" = true ]; then
    ninja -C "$BUILD_DIR" -t clean
fi

ninja -v -C "$BUILD_DIR" v8

mkdir -p "$OUTPUT_BASE/Lib/Linux"
if [ "$NEW_WRAP" == "with_new_wrap" ]; then 
  bash $GITHUB_WORKSPACE/rename_symbols_posix.sh x64 "$OUTPUT_BASE/Lib/Linux/"
fi

if [ -f "$BUILD_DIR/obj/libwee8.a" ]; then
    cp "$BUILD_DIR/obj/libwee8.a" "$OUTPUT_BASE/Lib/Linux/"
else
    echo "libwee8.a not found in $BUILD_DIR/obj, skipping."
fi
find "$BUILD_DIR" -type f -name "*.so" -exec cp "{}" "$OUTPUT_BASE/Lib/Linux" \;
find "$BUILD_DIR" -type f -name torque -exec cp "{}" "$OUTPUT_BASE/Lib/Linux" \;
find "$BUILD_DIR" -type f -name bytecode_builtins_list_generator -exec cp "{}" "$OUTPUT_BASE/Lib/Linux" \;

mkdir -p "$OUTPUT_BASE/Bin/Linux"
find "$BUILD_DIR" -type f -name v8cc -exec cp "{}" "$OUTPUT_BASE/Bin/Linux" \;
find "$BUILD_DIR" -type f -name mksnapshot -exec cp "{}" "$OUTPUT_BASE/Bin/Linux" \;

tar -cvzf "$TAR_NAME" -C "output/${BUILD_TYPE}" v8
