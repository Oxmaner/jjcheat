# ============================================================
#  JJCheat 2.1.0 — roothide 构建配置
#
#  2.1.0 变化：
#   - 源码按模块分目录（Core / Capture / Vision / Engine / Game / UI）
#   - 搜索引擎从 JS 换成独立进程 Pikafish（Engine/JJPikafish.m + posix_spawn）
#     pikafish 可执行文件由 engine/build-ios.sh 交叉编译后放进
#     layout/Library/Application Support/JJCheat/Pikafish/pikafish，
#     本 Makefile 只负责打包，不参与引擎编译（避免每次改 UI 都重编 30MB 引擎）
#   - JS 只剩「识别」，engine.js 从 ~285KB 降到 ~250KB
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

# roothide: jbroot() 来自 libroothide
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
JJCheat_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk

# ------------------------------------------------------------
#  打包前体检：引擎必须在 layout 里，否则装到手机上必然启动失败
#  用 JJ_SKIP_ENGINE_CHECK=1 可以跳过（只编 UI 时用）
# ------------------------------------------------------------
PIKA_BIN := $(THEOS_PROJECT_DIR)/layout/Library/Application Support/JJCheat/Pikafish/pikafish

before-package::
	@if [ "$(JJ_SKIP_ENGINE_CHECK)" != "1" ]; then \
	    if [ ! -f "$(PIKA_BIN)" ]; then \
	        echo "!! 缺少 Pikafish 可执行文件: $(PIKA_BIN)"; \
	        echo "!! 先跑 engine/build-ios.sh，或用 JJ_SKIP_ENGINE_CHECK=1 跳过"; \
	        exit 1; \
	    fi; \
	    echo ">> Pikafish: $$(wc -c < '$(PIKA_BIN)' | tr -d ' ') 字节"; \
	fi

after-install::
	install.exec "chmod 0755 '/Library/Application Support/JJCheat/Pikafish/pikafish' 2>/dev/null; killall -9 SpringBoard 2>/dev/null || true"
