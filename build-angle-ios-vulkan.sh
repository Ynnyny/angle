#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# --- depot_tools ---
if [ ! -d "depot_tools" ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
elif [ -d "depot_tools/.git" ]; then
    (cd depot_tools && git pull --depth 1)
fi
export PATH="$PATH:$SCRIPT_DIR/depot_tools"

# --- ANGLE source ---
if [ -f ".angle_commit" ]; then
    ANGLE_COMMIT=$(cat .angle_commit)
else
    ANGLE_COMMIT=${ANGLE_COMMIT:-""}
fi
if [ ! -d "angle" ]; then
    git clone --depth 1 https://chromium.googlesource.com/angle/angle
else
    (cd angle && git fetch --depth 1 origin main && git checkout FETCH_HEAD)
fi
if [ ! -z "$ANGLE_COMMIT" ]; then
    (cd angle && git fetch --depth 1 origin "$ANGLE_COMMIT" && git checkout "$ANGLE_COMMIT")
fi

# --- gclient sync ---
cd angle
gclient config --unmanaged https://chromium.googlesource.com/angle/angle
cat > .gclient << EOL
solutions = [
  {
    "name": ".",
    "url": "https://chromium.googlesource.com/angle/angle",
    "deps_file": "DEPS",
    "managed": False,
  },
]
EOL
gclient sync --shallow --no-history --noprehooks

# Install cipd deps explicitly (gn binary etc.); gclient skips deps_cipd when
# the solution is unmanaged.
cipd ensure -root buildtools/mac \
    -ensure-file - <<< "gn/gn/mac-arm64 git_revision:4ac29005ff1dc3d8f34ceb9c1438e2db8c1b0888"
if [ ! -x buildtools/mac/gn ]; then
    echo "ERROR: gn binary missing at buildtools/mac/gn" >&2
    exit 1
fi

# Ninja for the build
which ninja >/dev/null 2>&1 || brew install ninja

CURRENT_ANGLE_COMMIT=$(git rev-parse HEAD)
echo "Current ANGLE commit: $CURRENT_ANGLE_COMMIT"
echo "$CURRENT_ANGLE_COMMIT" > ../.angle_commit
cd ..

# --- common GN args (Vulkan backend + MoltenVK) ---
COMMON_ARGS='
    is_debug=false
    is_official_build=true
    chrome_pgo_phase=0
    ios_enable_code_signing=false
    is_component_build=false
    symbol_level=0
    strip_debug_info=true
    angle_enable_trace=false
    ios_deployment_target="16.0"
    angle_standalone=true
    angle_build_tests=false

    # Vulkan backend (reaches ES 3.2 on Apple via MoltenVK)
    angle_enable_vulkan=true
    angle_shared_libvulkan=true
    angle_use_custom_libvulkan=true
    angle_use_vulkan_display=false
    angle_enable_metal=false

    # Disable unused backends
    angle_enable_d3d9=false
    angle_enable_d3d11=false
    angle_enable_gl=false
    angle_enable_null=false
    angle_enable_wgpu=false
    angle_enable_swiftshader=false

    # Language settings
    angle_enable_essl=false
    angle_enable_glsl=true
    treat_warnings_as_errors=false
    use_custom_libcxx=true
'

# --- Build for iOS ARM64 device ---
echo "Building ANGLE (Vulkan) for iOS ARM64 device..."
GN_BIN="$SCRIPT_DIR/angle/buildtools/mac/gn"
"$GN_BIN" gen out/ios-vulkan-arm64 --args="
    target_os=\"ios\"
    target_cpu=\"arm64\"
    target_environment=\"device\"
    $COMMON_ARGS
"
ninja -C out/ios-vulkan-arm64 libEGL libGLESv2

# --- Assemble output ---
OUT=../build/ios-vulkan
rm -rf $OUT
mkdir -p $OUT
cp -R out/ios-vulkan-arm64/libEGL.framework $OUT/
cp -R out/ios-vulkan-arm64/libGLESv2.framework $OUT/
cp -R angle/include/EGL $OUT/include-EGL
cp -R angle/include/GLES2 $OUT/include-GLES2
cp -R angle/include/GLES3 $OUT/include-GLES3
cp -R angle/include/KHR $OUT/include-KHR
echo "$(git -C angle rev-parse HEAD)" > $OUT/commit.txt

# Ad-hoc codesign the framework binaries (required for iOS sideload)
for F in $OUT/libEGL.framework $OUT/libGLESv2.framework; do
    BIN=$(basename "$F" .framework)
    codesign -f -s - "$F/$BIN"
done

echo "Done. Frameworks in: $OUT"
ls -la $OUT/