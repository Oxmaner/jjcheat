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
                JJHUDWindow.m \
                JJEngineScript.c \
                JJMetalGrabber.m

# JJEngineScript.c 由 tools/gen-engine-c.py 从 dist/engine.js 生成（构建流水线里自动跑），
# 编进 dylib 作为 engine.js 的兜底副本 —— roothide 下 jbroot 路径随机 + App 沙箱跨容器限制，
# 只靠文件路径不可靠。

# include/ 里放了手写的 IOSurface 最小私有头（iOS SDK 只有二进制没有头）
# -Wno-error=int-to-void-pointer-cast: JJScreenGrabber 里 (void *)s_serverPort 这类
#   指针/整数互转告警，Xcode 16 的 clang 默认按 error 处理；降级成 warning，不改源码
JJCheat_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable \
                 -Wno-error=int-to-void-pointer-cast -Wno-error=void-pointer-to-int-cast \
                 -I$(THEOS_PROJECT_DIR)/include

JJCheat_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics JavaScriptCore \
                     IOSurface CoreVideo OpenGLES Metal MetalKit
JJCheat_PRIVATE_FRAMEWORKS =

# roothide: jbroot() 来自 libroothide
#   install-name = @loader_path/.jbroot/usr/lib/libroothide.dylib
#   stub 在 roothide/theos/vendor/lib/iphone/roothide/libroothide.tbd
# 开了 clang modules 时 modulemap 里的 link "roothide" 会自动链；这里显式再写一遍，
# USE_MODULES=0 或 modulemap 没生效时也不会漏
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
JJCheat_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
