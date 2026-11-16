#!/usr/bin/env bash
# ============================================================
#  Pikafish iOS 静态库构建（2.1.52 起：进程内运行）
#
#  必须在 macOS 上跑（需要 Xcode 的 iPhoneOS SDK + Apple libtool）。
#  本机 Windows 只能做语法检查，这一环永远交给 GitHub Actions 的 macos-15。
#
#  产物：
#    ios/tweak/Engine/lib/libpikafish.a        引擎 + 桥接层（链进 JJCheat.dylib）
#    ios/tweak/Engine/jjpika_shim.h            桥接层头文件
#    ios/tweak/layout/.../pikafish.nnue        NNUE 权重（随包分发）
#
#  为什么不再是可执行文件：
#    2.1.51 真机日志证明 iOS App 沙盒不允许对自己容器与 jbroot 下的二进制
#    做 exec（access(X_OK) 一路 EPERM），posix_spawn 那条路走不通。
#    改成静态库链进 dylib，引擎在进程内跑，沙盒再也拦不到。
#
#  用法:
#    engine/build-ios.sh                 # 默认 tag + 默认输出
#    PIKA_TAG=master engine/build-ios.sh # 试最新 master
#    PIKA_FORCE=1 engine/build-ios.sh    # 忽略缓存重编
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${PIKA_TAG:-Pikafish-2026-09-06}"
REPO="${PIKA_REPO:-https://github.com/official-pikafish/Pikafish.git}"
WORK="$ROOT/engine/.build"
SRC="$WORK/src"
OBJ="$WORK/obj"
MIN_IOS="${PIKA_MIN_IOS:-14.0}"
NFORCE="${PIKA_FORCE:-0}"

LIB_OUT_DIR="$ROOT/ios/tweak/Engine/lib"
LIB_OUT="$LIB_OUT_DIR/libpikafish.a"
SHIM_SRC="$ROOT/ios/tweak/Engine/jjpika_shim.cpp"
DEST_DIR="$ROOT/ios/tweak/layout/Library/Application Support/JJCheat/Pikafish"
DEST_NET="$DEST_DIR/pikafish.nnue"

log() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 环境体检 ----------
[ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上交叉编译（当前 $(uname -s)）"
command -v xcrun >/dev/null || die "找不到 xcrun，先装 Xcode Command Line Tools"
SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
[ -d "$SDK" ] || die "找不到 iPhoneOS SDK（xcrun --sdk iphoneos --show-sdk-path 为空）"
CLANGXX="$(xcrun --find clang++ 2>/dev/null || command -v clang++)"
[ -n "$CLANGXX" ] || die "找不到 clang++"
log "SDK   : $SDK"
log "clang : $CLANGXX"
log "目标  : arm64-apple-ios$MIN_IOS"

TARGET_FLAGS="-target arm64-apple-ios$MIN_IOS -isysroot $SDK -mios-version-min=$MIN_IOS"

# ---------- 取源码 ----------
mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
    log "克隆 Pikafish@$TAG"
    rm -rf "$SRC"
    git clone --depth 1 --branch "$TAG" "$REPO" "$SRC" \
        || die "克隆失败（tag $TAG 是否存在？）"
else
    CUR="$(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"
    if [ "$CUR" != "$TAG" ] && [ "$NFORCE" != "1" ]; then
        log "已有源码是 ${CUR}，切换不到 $TAG 时请 PIKA_FORCE=1 重来"
    fi
    log "复用已有源码: $CUR"
fi

cd "$SRC/src"

# ---------- NNUE 网络 ----------
if [ ! -f pikafish.nnue ]; then
    log "下载 NNUE 网络（约 48~60MB）"
    sh ../scripts/net.sh || die "NNUE 下载失败（GitHub Releases 不通？）"
else
    log "复用已有 NNUE: $(wc -c < pikafish.nnue | tr -d ' ') 字节"
fi
[ -s pikafish.nnue ] || die "pikafish.nnue 是空的"
NET_SIZE="$(wc -c < pikafish.nnue | tr -d ' ')"
[ "$NET_SIZE" -gt 20000000 ] || die "pikafish.nnue 只有 $NET_SIZE 字节，下载不完整"
log "权重   : $NET_SIZE 字节"

# ---------- 编译静态库 ----------
# 关键 flag 说明：
#  -fno-exceptions   Pikafish 全库按无异常编译（官方 Makefile 同款）
#  -fPIC             要链进 dylib，必须位置无关（不能沿用可执行版本的
#                    -mdynamic-no-pic，那会让链接直接报错）
#  -DUSE_NEON=8      arm64 的 NEON 通路
#  -DUSE_PTHREADS    引擎内部多线程
#  不编 main.cpp     入口由 jjpika_shim.cpp 提供
CXXSTD="-std=c++17"
CFLAGS_COMMON="$TARGET_FLAGS $CXXSTD -O3 -DNDEBUG -fno-exceptions -fPIC -funroll-loops \
 -DIS_64BIT -DUSE_NEON=8 -DUSE_PTHREADS -fno-strict-aliasing"

if [ -f "$LIB_OUT" ] && [ "$NFORCE" != "1" ] \
   && [ "$LIB_OUT" -nt pikafish.nnue ] && [ "$LIB_OUT" -nt "$SHIM_SRC" ]; then
    log "已存在静态库且比网络新，跳过编译（PIKA_FORCE=1 可强制重编）"
else
    JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    log "编译中（-j${JOBS}，全量约 3~6 分钟）"
    rm -rf "$OBJ"
    mkdir -p "$OBJ"

    # 先编引擎，再编桥接层。
    # 排除 main.cpp（入口由桥接层提供）与 universal/（那是给 x86/riscv 的
    # 通用二进制入口桩，官方 Makefile 也只在 UNIVERSAL_BINARY 时才编）。
    find . -name '*.cpp' ! -name 'main.cpp' ! -path './universal/*' -print > "$WORK/sources.txt"
    echo "$SHIM_SRC" >> "$WORK/sources.txt"
    wc -l < "$WORK/sources.txt" | tr -d ' ' | sed 's/^/   源文件数: /'

    # 每个 .cpp 一个 .o，文件名用路径哈希避免同名（如两个 debug.cpp）
    build_one() {
        src_path="$1"
        rel="${src_path#./}"
        rel="${rel#$ROOT/}"
        obj="$OBJ/$(printf '%s' "$rel" | shasum -a 256 | cut -c1-16).o"
        extra=""
        case "$rel" in
            *jjpika_shim.cpp) extra="-I$SRC/src" ;;
        esac
        "$CLANGXX" $CFLAGS_COMMON $extra -c "$src_path" -o "$obj" 2>>"$WORK/build.log"
    }
    export -f build_one
    export CLANGXX CFLAGS_COMMON OBJ SRC WORK ROOT

    : > "$WORK/build.log"
    if ! xargs -P "$JOBS" -I{} bash -c 'build_one "$@"' _ {} < "$WORK/sources.txt"; then
        tail -40 "$WORK/build.log"
        die "编译失败，完整日志: $WORK/build.log"
    fi

    log "归档 libpikafish.a"
    mkdir -p "$LIB_OUT_DIR"
    rm -f "$LIB_OUT"
    /usr/bin/libtool -static -o "$LIB_OUT" "$OBJ"/*.o 2>>"$WORK/build.log" \
        || die "libtool 归档失败，日志: $WORK/build.log"
fi

[ -s "$LIB_OUT" ] || die "没有产出 $LIB_OUT"
LIB_SIZE="$(wc -c < "$LIB_OUT" | tr -d ' ')"
log "静态库 : $LIB_SIZE 字节"

# 桥接层符号必须在库里
for sym in jjpika_start jjpika_stop jjpika_send jjpika_recv; do
    if ! nm -g "$LIB_OUT" 2>/dev/null | grep -q " T _${sym}$"; then
        die "静态库里缺符号 _${sym}"
    fi
done
log "符号齐全: jjpika_start/stop/send/recv"

# ---------- 落盘 ----------
mkdir -p "$DEST_DIR"
cp -f pikafish.nnue "$DEST_NET"
chmod 0644 "$DEST_NET"
log "已放置: $LIB_OUT"
log "已放置: $DEST_NET"
log "sha256(lib): $(shasum -a 256 "$LIB_OUT" | cut -d' ' -f1)"
log "sha256(net): $(shasum -a 256 "$DEST_NET" | cut -d' ' -f1)"
echo
echo "下一步：cd ios/tweak && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide"
