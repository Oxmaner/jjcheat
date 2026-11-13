//
//  IOSurface.h  （最小私有头文件）
//  JJCheat
//
//  IOSurface 是私有框架：iPhoneOS SDK 里只有二进制，没有头文件。
//  这里只声明 JJScreenGrabber.m 实际用到的 5 个函数和 1 个常量，
//  签名照真机 ABI 写，避免引入整套 runtime headers。
//

#ifndef JJ_IOSURFACE_H
#define JJ_IOSURFACE_H

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stddef.h>

typedef struct __IOSurface *IOSurfaceRef;

#ifdef __cplusplus
extern "C" {
#endif

enum {
    kIOSurfaceLockReadOnly  = 0x00000001,
    kIOSurfaceLockAvoidSync = 0x00000002,
};

IOSurfaceRef  IOSurfaceCreate(CFDictionaryRef properties);
kern_return_t IOSurfaceLock(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
kern_return_t IOSurfaceUnlock(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
size_t        IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
void         *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);

#ifdef __cplusplus
}
#endif

#endif /* JJ_IOSURFACE_H */
