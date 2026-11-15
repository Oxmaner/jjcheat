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

TARGET := iphone:clang:latest:14.0
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

JJCheat_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable
JJCheat_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics JavaScriptCore \
                     IOSurface CoreVideo OpenGLES Metal MetalKit
JJCheat_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
