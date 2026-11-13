//
//  IOSurface.h  （转发头）
//  JJCheat
//
//  iOS SDK 里 IOSurface 是私有框架：framework/Headers 下只提供
//  IOSurfaceBase.h / IOSurfaceTypes.h / IOSurfaceRef.h / IOSurfaceObjC.h，
//  没有惯用的 IOSurface.h 伞形头，所以 #import <IOSurface/IOSurface.h> 会报
//  “file not found”。这里只做一层转发，不重复声明任何东西——枚举
//  kIOSurfaceLockReadOnly 等由 SDK 的 IOSurfaceTypes.h 定义，函数的声明
//  由 IOSurfaceRef.h 给出，重复定义会被 -Werror 直接拦下。
//

#ifndef JJ_IOSURFACE_H
#define JJ_IOSURFACE_H

#include <IOSurface/IOSurfaceBase.h>
#include <IOSurface/IOSurfaceTypes.h>
#include <IOSurface/IOSurfaceRef.h>

#endif /* JJ_IOSURFACE_H */
