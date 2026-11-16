#!/usr/bin/env bash
# ============================================================
#  Pikafish iOS 静态库构建（2.1.52 起：进程内运行）
#
#  必须在 macOS 上跑（需要 Xcode 的 iPhoneOS SDK + Apple libtool）。
#  本机 Windows 只能做语法检查，这一环永远交给 GitHub Actions 的 macos-15。
#
#  产物：
#    ios/tweak/Engine/lib/libpikafish.a    引擎 + 桥接层（链进 JJCheat.dylib）
#    ios/tweak/layout/.../pikafish.nnue    NNUE 权重（随包分发）
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
# 关键 flag：
#  -fno-exceptions   Pikafish 全库按无异常编译（官方 Makefile 同款）
#  -fPIC             要链进 dylib，必须位置无关（不能沿用可执行版本的
#                    -mdynamic-no-pic，那会让链接直接报错）
#  -DUSE_NEON=8      arm64 的 NEON 通路
#  -DUSE_PTHREADS    引擎内部多线程
#  不编 main.cpp     入口由 jjpika_shim.cpp 提供
CXXSTD="-std=c++17"
CFLAGS_COMMON="$TARGET_FLAGS $CXXSTD -O3 -DNDEBUG -fno-exceptions -fPIC -funroll-loops \
 -DIS_64BIT -DUSE_NEON=8 -DUSE_PTHREADS -fno-strict-aliasing"

needs_build() {
    [ "$NFORCE" = "1" ] && return 0
    [ -f "$LIB_OUT" ] || return 0
    [ "$LIB_OUT" -nt pikafish.nnue ] || return 0
    [ "$LIB_OUT" -nt "$SHIM_SRC" ] || return 0
    # 库存在但桥接符号缺失（上次编到一半）→ 重编
    nm -g "$LIB_OUT" 2>/dev/null | grep -q " T _jjpika_start$" || return 0
    return 1
}

if ! needs_build; then
    log "静态库已是最新，跳过编译（PIKA_FORCE=1 可强制重编）"
else
    log "编译中（共 $(find . -name '*.cpp' ! -name 'main.cpp' ! -path './universal/*' | wc -l | tr -d ' ') 个引擎文件 + 1 个桥接层）"
    rm -rf "$OBJ"
    mkdir -p "$OBJ"

    # 逐个编译，不用 xargs + export -f：非交互 bash 下函数导出的行为不稳，
    # 而且顺序编译更容易在日志里定位是哪个文件出的问题（总计约 30~60s）。
    IDX=0
    FAILED=0
    while IFS= read -r f; do
        IDX=$((IDX + 1))
        obj="$OBJ/$(printf '%03d' "$IDX").o"
        if ! "$CLANGXX" $CFLAGS_COMMON -c "$f" -o "$obj" 2>"$obj.log"; then
            echo "!! 编译失败: $f"
            grep -E "error:" "$obj.log" | head -6 || cat "$obj.log" | head -20
            FAILED=$((FAILED + 1))
            continue
        fi
        rm -f "$obj.log"
    done < <(find . -name '*.cpp' ! -name 'main.cpp' ! -path './universal/*' | sort)
    [ "$FAILED" -eq 0 ] || die "$FAILED 个文件编译失败"

    # 桥接层单独编（要额外加引擎源码目录进 include path）
    log "编译桥接层 jjpika_shim.cpp"
    IDX=$((IDX + 1))
    SHIM_OBJ="$OBJ/$(printf '%03d' "$IDX").o"
    if ! "$CLANGXX" $CFLAGS_COMMON -I"$SRC/src" -c "$SHIM_SRC" -o "$SHIM_OBJ" 2>"$WORK/shim.log"; then
        grep -E "error:" "$WORK/shim.log" | head -10 || cat "$WORK/shim.log" | head -40
        die "桥接层编译失败（日志: $WORK/shim.log）"
    fi

    OBJ_COUNT="$(ls "$OBJ"/*.o 2>/dev/null | wc -l | tr -d ' ')"
    log "目标文件: $OBJ_COUNT 个"
    [ "$OBJ_COUNT" -ge 30 ] || die "只产出 $OBJ_COUNT 个 .o，明显不对"

    log "归档 libpikafish.a"
    mkdir -p "$LIB_OUT_DIR"
    rm -f "$LIB_OUT"
    /usr/bin/libtool -static -o "$LIB_OUT" "$OBJ"/*.o \
        || die "libtool 归档失败"
fi

[ -s "$LIB_OUT" ] || die "没有产出 $LIB_OUT"
LIB_SIZE="$(wc -c < "$LIB_OUT" | tr -d ' ')"
log "静态库 : $LIB_SIZE 字节"

# 桥接层符号必须在库里（缺一个就说明桥接层没编进来）
MISSING=0
for sym in jjpika_start jjpika_stop jjpika_send jjpika_recv jjpika_running; do
    if ! nm -g "$LIB_OUT" 2>/dev/null | grep -q " T _${sym}$"; then
        echo "!! 静态库里缺符号 _${sym}"
        MISSING=$((MISSING + 1))
    fi
done
if [ "$MISSING" -ne 0 ]; then
    echo "--- 库里前 20 个外部符号 ---"
    nm -g "$LIB_OUT" 2>/dev/null | grep " T " | head -20
    die "桥接层符号不全（缺 $MISSING 个）"
fi
log "符号齐全: jjpika_start/stop/send/recv/running"

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
