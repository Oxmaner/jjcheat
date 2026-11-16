# ============================================================
#  JJCheat 2.1.52 — roothide 构建配置
#
#  2.1.52 变化：
#   - 引擎改进程内：Pikafish 由 engine/build-ios.sh 编译成静态库
#     Engine/lib/libpikafish.a，直接链进 JJCheat.dylib。
#     原因：iOS App 沙盒不允许 exec 自己容器与 jbroot 下的二进制，2.1.51
#     之前 posix_spawn 独立进程的方案真机上一条 spawn 都发不出去。
#   - 包里只剩 NNUE 权重一个引擎资源（layout/.../pikafish.nnue）
#   - 源码按模块分目录（Core / Capture / Vision / Engine / Game / UI）
#   - JS 只剩「识别」，engine.js 约 250KB
#
#  roothide 方案做的事:
#   1) dylib install_name 变成 @loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/JJCheat.dylib
#   2) 包 Architecture 变成 iphoneos-arm64e（roothide 的包架构名）
#   3) 不再注入 -lroot（那是 rootless /var/jb 的兼容库）
# ============================================================

TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

# roothide 打包方案（关键）
THEOS_PACKAGE_SCHEME = roothide

DISABLE_ROOTLESS_COMPAT_WARNING = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = JJCheat

JJCheat_FILES = Tweak.x \
                Game/JJGameController.m \
                Game/JJCalibrator.m \
                UI/JJHUDWindow.m \
                UI/JJBallWindow.m \
                Vision/JJVisionBridge.m \
                Vision/JJEngineScript.c \
                Capture/JJMetalGrabber.m \
                Capture/JJScreenGrabber.m \
                Engine/JJPikafish.m \
                Engine/JJPikafishInstaller.m \
                Engine/JJMoveCodec.m

JJ_CORE := $(THEOS_PROJECT_DIR)/Core
JJ_CAPTURE := $(THEOS_PROJECT_DIR)/Capture
JJ_VISION := $(THEOS_PROJECT_DIR)/Vision
JJ_ENGINE := $(THEOS_PROJECT_DIR)/Engine
JJ_GAME := $(THEOS_PROJECT_DIR)/Game
JJ_UI := $(THEOS_PROJECT_DIR)/UI

# 各模块目录都要进 include path，源文件之间是平铺 #import "XXX.h"
# include/ 里放了手写的 IOSurface 伞头（iOS SDK 的 IOSurface 框架没有 IOSurface.h，
# 只有 Base/Types/Ref/ObjC 四个头，不加这层转发 <IOSurface/IOSurface.h> 直接 not found）
JJCheat_CFLAGS = -fobjc-arc -O2 -std=gnu11 \
                 -Wno-deprecated-declarations -Wno-unused-variable \
                 -Wno-error=int-to-void-pointer-cast -Wno-error=void-pointer-to-int-cast \
                 -I$(THEOS_PROJECT_DIR)/include \
                 -I$(JJ_CORE) -I$(JJ_CAPTURE) -I$(JJ_VISION) \
                 -I$(JJ_ENGINE) -I$(JJ_GAME) -I$(JJ_UI)

JJCheat_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics JavaScriptCore \
                     IOSurface CoreVideo OpenGLES Metal MetalKit
JJCheat_PRIVATE_FRAMEWORKS =

# 进程内 Pikafish：静态库 + C++ 运行时
# 引擎自身用 -fno-exceptions 编译，但桥接层用到了 std::string/deque/iostream，
# 必须把 libc++ 链上，否则一堆 std::__1:: 符号未定义。
PIKA_LIB := $(JJ_ENGINE)/lib/libpikafish.a
JJCheat_LDFLAGS = -L$(JJ_ENGINE)/lib -lpikafish -lc++ -Wl,-dead_strip

# roothide: jbroot() 来自 libroothide
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
JJCheat_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk

# ------------------------------------------------------------
#  打包前体检：静态库与权重都必须在，否则装上去引擎必然起不来
#  用 JJ_SKIP_ENGINE_CHECK=1 可以跳过（只编 UI 时用）
# ------------------------------------------------------------
PIKA_DIR := $(THEOS_PROJECT_DIR)/layout/Library/Application Support/JJCheat/Pikafish
PIKA_NET := $(PIKA_DIR)/pikafish.nnue

before-package::
	@if [ "$(JJ_SKIP_ENGINE_CHECK)" != "1" ]; then \
	    if [ ! -f "$(PIKA_LIB)" ]; then \
	        echo "!! 缺少引擎静态库: $(PIKA_LIB)"; \
	        echo "!! 先跑 engine/build-ios.sh，或用 JJ_SKIP_ENGINE_CHECK=1 跳过"; \
	        exit 1; \
	    fi; \
	    if [ ! -f "$(PIKA_NET)" ]; then \
	        echo "!! 缺少 NNUE 权重: $(PIKA_NET)"; \
	        exit 1; \
	    fi; \
	    echo ">> libpikafish.a: $$(wc -c < '$(PIKA_LIB)' | tr -d ' ') 字节"; \
	    echo ">> pikafish.nnue: $$(wc -c < '$(PIKA_NET)' | tr -d ' ') 字节"; \
	fi

after-install::
	install.exec "killall -9 SpringBoard 2>/dev/null || true"
