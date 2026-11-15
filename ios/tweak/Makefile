# ============================================================
#  JJCheat — roothide 适配构建配置
#  上游工程: https://github.com/lichengyang51/jjcheat (ios/tweak)
#  这里只改“构建/打包”相关变量，Tweak 源码一行未动。
#
#  roothide 方案做的事:
#   1) dylib install_name 变成 @loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/JJCheat.dylib
#   2) 包 Architecture 变成 iphoneos-arm64e（roothide 的包架构名）
#   3) 不再注入 -lroot（那是 rootless /var/jb 的兼容库）
#  依赖: roothide/theos  (https://github.com/roothide/theos)
# ============================================================

TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

# roothide 打包方案（关键）
THEOS_PACKAGE_SCHEME = roothide

# 老工程可能用 ROOT_PATH 之类的 rootless 宏，roothide/theos 会提醒；本工程用字面量路径，提醒关掉
DISABLE_ROOTLESS_COMPAT_WARNING = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = JJCheat

JJCheat_FILES = Tweak.xm \
                JJController.m \
                JJEngineBridge.m \
                JJScreenGrabber.m \
                JJHUDWindow.m

# include/ 里放了手写的 IOSurface 最小私有头（iOS SDK 只有二进制没有头）
# -Wno-error=int-to-void-pointer-cast: JJScreenGrabber 里 (void *)s_serverPort 这类
#   指针/整数互转告警，Xcode 16 的 clang 默认按 error 处理；降级成 warning，不改源码
JJCheat_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable \
                 -Wno-error=int-to-void-pointer-cast -Wno-error=void-pointer-to-int-cast \
                 -I$(THEOS_PROJECT_DIR)/include

JJCheat_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics JavaScriptCore \
                     IOSurface CoreVideo OpenGLES Metal MetalKit
JJCheat_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
