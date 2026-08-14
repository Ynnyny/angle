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

# Patch vulkan-loader GN: it only defines SYSCONFDIR/FALLBACK_* for
# linux/chromeos/mac; iOS needs them too (ANGLE iOS upstream is Metal-only,
# so this never ran there).
sed -i '' \
    -e 's/if (is_linux || is_chromeos || is_mac) {/if (is_linux || is_chromeos || is_mac || is_ios) {/' \
    -e 's/if (is_mac) {/if (is_mac || is_ios) {/' \
    third_party/vulkan-loader/src/BUILD.gn

# Enable the macOS-style Vulkan display/WSI on iOS: DisplayVkMac + WindowSurfaceVkMac
# use only Foundation/QuartzCore (CAMetalLayer) + Metal, both available on iOS.
# IOSurfaceSurfaceVkMac (EGL_IOSURFACE_ANGLE client buffers) stays macOS-only.
python3 - <<'PYEOF'
import re
gni = 'src/libANGLE/renderer/vulkan/vulkan_backend.gni'
s = open(gni).read()
old = '''if (is_mac) {
  vulkan_backend_sources += [
    "mac/DisplayVkMac.h",
    "mac/DisplayVkMac.mm",
    "mac/IOSurfaceSurfaceVkMac.h",
    "mac/IOSurfaceSurfaceVkMac.mm",
    "mac/WindowSurfaceVkMac.h",
    "mac/WindowSurfaceVkMac.mm",
  ]
}
'''
new = '''if (is_mac || is_ios) {
  vulkan_backend_sources += [
    "mac/DisplayVkMac.h",
    "mac/DisplayVkMac.mm",
    "mac/WindowSurfaceVkMac.h",
    "mac/WindowSurfaceVkMac.mm",
  ]
}
if (is_mac) {
  vulkan_backend_sources += [
    "mac/IOSurfaceSurfaceVkMac.h",
    "mac/IOSurfaceSurfaceVkMac.mm",
  ]
}
'''
assert old in s, "vulkan_backend.gni block not found"
open(gni, 'w').write(s.replace(old, new))

mm = 'src/libANGLE/renderer/vulkan/mac/DisplayVkMac.mm'
s = open(mm).read()
s = s.replace('#import <Cocoa/Cocoa.h>',
              '#import <Foundation/Foundation.h>\n#import <QuartzCore/QuartzCore.h>\n#include <TargetConditionals.h>')
s = s.replace('#import <Foundation/Foundation.h>\n#import <QuartzCore/QuartzCore.h>\n#include <TargetConditionals.h>\n#include <TargetConditionals.h>',
              '#import <Foundation/Foundation.h>\n#import <QuartzCore/QuartzCore.h>\n#include <TargetConditionals.h>')
s = s.replace('''#if TARGET_OS_IPHONE
    return nullptr;
#else
    return new IOSurfaceSurfaceVkMac(state, clientBuffer, attribs, mRenderer);
#endif''', '')  # idempotence guard
s = s.replace('''    ASSERT(buftype == EGL_IOSURFACE_ANGLE);

    return new IOSurfaceSurfaceVkMac(state, clientBuffer, attribs, mRenderer);''',
'''    ASSERT(buftype == EGL_IOSURFACE_ANGLE);
#if TARGET_OS_IPHONE
    return nullptr;
#else
    return new IOSurfaceSurfaceVkMac(state, clientBuffer, attribs, mRenderer);
#endif''')
s = s.replace('''    if (!IOSurfaceSurfaceVkMac::ValidateAttributes(this, clientBuffer, attribs))
    {
        return egl::Error(EGL_BAD_ATTRIBUTE);
    }''',
'''#if !TARGET_OS_IPHONE
    if (!IOSurfaceSurfaceVkMac::ValidateAttributes(this, clientBuffer, attribs))
    {
        return egl::Error(EGL_BAD_ATTRIBUTE);
    }
#endif''')
s = s.replace('outExtensions->iosurfaceClientBuffer = true;',
              '#if !TARGET_OS_IPHONE\n    outExtensions->iosurfaceClientBuffer = true;\n#endif')
open(mm, 'w').write(s)

h = 'src/libANGLE/renderer/vulkan/mac/WindowSurfaceVkMac.h'
s = open(h).read()
s = s.replace('#include <Cocoa/Cocoa.h>',
              '#include <Foundation/Foundation.h>\n#include <QuartzCore/QuartzCore.h>')
open(h, 'w').write(s)

mmw = 'src/libANGLE/renderer/vulkan/mac/WindowSurfaceVkMac.mm'
s = open(mmw).read()
s = s.replace('#include <Metal/Metal.h>',
              '#include <TargetConditionals.h>\n#include <Metal/Metal.h>')
s = s.replace('''    mMetalLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
''', '''#if !TARGET_OS_IPHONE
    mMetalLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
#endif
''')
open(mmw, 'w').write(s)
PYEOF

CURRENT_ANGLE_COMMIT=$(git rev-parse HEAD)
echo "Current ANGLE commit: $CURRENT_ANGLE_COMMIT"
echo "$CURRENT_ANGLE_COMMIT" > ../.angle_commit

# NOTE: stay inside angle/ from here on — gn/ninja must run against the
# gclient-synced checkout (which contains build/ etc.), not the fork root.

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
cp -R include/EGL $OUT/include-EGL
cp -R include/GLES2 $OUT/include-GLES2
cp -R include/GLES3 $OUT/include-GLES3
cp -R include/KHR $OUT/include-KHR
echo "$(git rev-parse HEAD)" > $OUT/commit.txt

# Ad-hoc codesign the framework binaries (required for iOS sideload)
for F in $OUT/libEGL.framework $OUT/libGLESv2.framework; do
    BIN=$(basename "$F" .framework)
    codesign -f -s - "$F/$BIN"
done

echo "Done. Frameworks in: $OUT"
ls -la $OUT/