//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// WindowSurfaceVkMac.mm:
//    Implements methods from WindowSurfaceVkMac.
//

#include "libANGLE/renderer/vulkan/mac/WindowSurfaceVkMac.h"

#include <TargetConditionals.h>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>

#include "libANGLE/renderer/vulkan/vk_renderer.h"
#include "libANGLE/renderer/vulkan/vk_utils.h"

namespace rx
{

WindowSurfaceVkMac::WindowSurfaceVkMac(const egl::SurfaceState &surfaceState,
                                       EGLNativeWindowType window)
    : WindowSurfaceVk(surfaceState, window), mMetalLayer(nullptr)
{}

WindowSurfaceVkMac::~WindowSurfaceVkMac()
{
    [mMetalDevice release];
    [mMetalLayer release];
}

angle::Result WindowSurfaceVkMac::createSurfaceVk(vk::ErrorContext *context)
{
    mMetalDevice = MTLCreateSystemDefaultDevice();

    CALayer *layer = reinterpret_cast<CALayer *>(mNativeWindowType);

    // NOTE(apple/ios): If the native window type is already a CAMetalLayer,
    // render into it directly instead of wrapping it in a brand-new sublayer.
    // A CAMetalLayer created and attached from the GL thread (the layer tree
    // is owned by the main thread) can end up ignored by the window server,
    // so drawables presented on it never reach the display (black screen).
    // This mirrors the Metal backend (SurfaceMtl.mm), which uses the caller's
    // layer directly whenever it is one. On iOS EGL window surfaces are
    // typically the CALayer itself; the sublayer path stays for NSView-style
    // windows (macOS).
    if ([layer isKindOfClass:[CAMetalLayer class]])
    {
        mMetalLayer = static_cast<CAMetalLayer *>(layer);
        [mMetalLayer retain];
    }
    else
    {
        mMetalLayer        = [[CAMetalLayer alloc] init];
        mMetalLayer.frame  = CGRectMake(0, 0, layer.frame.size.width, layer.frame.size.height);
    #if !TARGET_OS_IPHONE
    mMetalLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
#endif
        [layer addSublayer:mMetalLayer];
    }
    mMetalLayer.device = mMetalDevice;
    mMetalLayer.drawableSize =
        CGSizeMake(mMetalLayer.bounds.size.width * mMetalLayer.contentsScale,
                   mMetalLayer.bounds.size.height * mMetalLayer.contentsScale);
    mMetalLayer.framebufferOnly  = NO;
    mMetalLayer.contentsScale    = layer.contentsScale;

    VkMetalSurfaceCreateInfoEXT createInfo = {};
    createInfo.sType                       = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
    createInfo.flags                       = 0;
    createInfo.pNext                       = nullptr;
    createInfo.pLayer                      = mMetalLayer;
    ANGLE_VK_TRY(context, VK_CALL(vkCreateMetalSurfaceEXT, context->getRenderer()->getInstance(),
                                  &createInfo, nullptr, &mSurface));

    return angle::Result::Continue;
}

angle::Result WindowSurfaceVkMac::getCurrentWindowSize(vk::ErrorContext *context,
                                                       gl::Extents *extentsOut) const
{
    ANGLE_VK_CHECK(context, (mMetalLayer != nullptr), VK_ERROR_INITIALIZATION_FAILED);

    mMetalLayer.drawableSize =
        CGSizeMake(mMetalLayer.bounds.size.width * mMetalLayer.contentsScale,
                   mMetalLayer.bounds.size.height * mMetalLayer.contentsScale);
    *extentsOut = gl::Extents(static_cast<int>(mMetalLayer.drawableSize.width),
                              static_cast<int>(mMetalLayer.drawableSize.height), 1);

    return angle::Result::Continue;
}

}  // namespace rx
