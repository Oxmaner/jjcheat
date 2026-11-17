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

# ---------- 源码补丁（2.1.68 起） ----------
# Network::verify 在「网络没加载成功」时会 exit(EXIT_FAILURE)，而 Engine::go
# 第一句就是 verify_network()。我们是进程内引擎，那个 exit 会把宿主 App 一起
# 杀掉（真机 .ips thread 91 就停在那）。补丁把它改成返回 bool，并把失败原因
# 带 decompressed/fileHash/engineHash 报出来。详见 engine/patch-engine.py。
command -v python3 >/dev/null || die "找不到 python3（应用源码补丁需要）"
log "应用引擎补丁"
python3 "$ROOT/engine/patch-engine.py" "$SRC/src" || die "引擎补丁没打上（源码结构与预期不符，拒绝产出坏包）"

# ---------- 编译静态库 ----------
# 关键 flag：
#  -fno-exceptions   Pikafish 全库按无异常编译（官方 Makefile 同款）
#  -fPIC             要链进 dylib，必须位置无关（不能沿用可执行版本的
#                    -mdynamic-no-pic，那会让链接直接报错）
#  -DUSE_NEON=8      arm64 的 NEON 通路
#  -DUSE_PTHREADS    引擎内部多线程
#  不编 main.cpp     入口由 jjpika_shim.cpp 提供
CXXSTD="-std=c++17"
# 注意：不能带 -target/-mios-version-min，各架构要分别拼
CFLAGS_BASE="$CXXSTD -O3 -DNDEBUG -fno-exceptions -fPIC -funroll-loops \
 -DIS_64BIT -DUSE_NEON=8 -DUSE_PTHREADS -fno-strict-aliasing"

# theos 的 TARGET 是 iphone:clang:16.5:14.0 + ARCHS="arm64 arm64e"，
# 最终 dylib 是双架构 fat；静态库只有 arm64 的话 arm64e 那片会整个被 ld 忽略，
# 报一堆 Undefined symbols for architecture arm64e。所以两个架构都要编，最后 lipo 合并。
ARCH_LIST="arm64 arm64e"

needs_build() {
    [ "$NFORCE" = "1" ] && return 0
    [ -f "$LIB_OUT" ] || return 0
    [ "$LIB_OUT" -nt pikafish.nnue ] || return 0
    [ "$LIB_OUT" -nt "$SHIM_SRC" ] || return 0
    # 库存在但桥接符号缺失（上次编到一半）→ 重编
    nm -g "$LIB_OUT" 2>/dev/null | grep -q " T _jjpika_start$" || return 0
    # 库是「没打补丁」的旧产物（缺 jj_last_network_load_error）→ 重编
    nm -g "$LIB_OUT" 2>/dev/null | grep -q " T _jj_last_network_load_error$" || return 0
    # 只有单架构（旧产物）也要重编
    lipo -info "$LIB_OUT" 2>/dev/null | grep -q "arm64e" || return 0
    return 1
}

if ! needs_build; then
    log "静态库已是最新，跳过编译（PIKA_FORCE=1 可强制重编）"
else
    SRC_LIST="$WORK/sources.txt"
    find . -name '*.cpp' ! -name 'main.cpp' ! -path './universal/*' | sort > "$SRC_LIST"
    ENGINE_COUNT="$(wc -l < "$SRC_LIST" | tr -d ' ')"
    log "编译中（$ENGINE_COUNT 个引擎文件 + 1 个桥接层，架构: ${ARCH_LIST}）"
    rm -rf "$OBJ"
    mkdir -p "$OBJ"

    for arch in $ARCH_LIST; do
        ARCH_FLAGS="-target $arch-apple-ios$MIN_IOS -isysroot $SDK -mios-version-min=$MIN_IOS"
        mkdir -p "$OBJ/$arch"
        log "  [$arch] 编译引擎"
        IDX=0
        FAILED=0
        while IFS= read -r f; do
            IDX=$((IDX + 1))
            obj="$OBJ/$arch/$(printf '%03d' "$IDX").o"
            if ! "$CLANGXX" $ARCH_FLAGS $CFLAGS_BASE -c "$f" -o "$obj" 2>"$obj.log"; then
                echo "!! [$arch] 编译失败: $f"
                grep -E "error:" "$obj.log" | head -6 || head -20 "$obj.log"
                FAILED=$((FAILED + 1))
                continue
            fi
            rm -f "$obj.log"
        done < "$SRC_LIST"
        [ "$FAILED" -eq 0 ] || die "[$arch] $FAILED 个文件编译失败"

        IDX=$((IDX + 1))
        SHIM_OBJ="$OBJ/$arch/$(printf '%03d' "$IDX").o"
        if ! "$CLANGXX" $ARCH_FLAGS $CFLAGS_BASE -I"$SRC/src" \
                -c "$SHIM_SRC" -o "$SHIM_OBJ" 2>"$WORK/shim-$arch.log"; then
            echo "!! [$arch] 桥接层编译失败"
            grep -E "error:" "$WORK/shim-$arch.log" | head -10 || head -40 "$WORK/shim-$arch.log"
            die "桥接层编译失败（日志: $WORK/shim-$arch.log）"
        fi

        OBJ_COUNT="$(ls "$OBJ/$arch"/*.o 2>/dev/null | wc -l | tr -d ' ')"
        log "  [$arch] 目标文件 $OBJ_COUNT 个"
        [ "$OBJ_COUNT" -ge 30 ] || die "[$arch] 只产出 $OBJ_COUNT 个 .o，明显不对"

        /usr/bin/libtool -static -o "$WORK/libpikafish-$arch.a" "$OBJ/$arch"/*.o \
            || die "[$arch] libtool 归档失败"
    done

    log "合并双架构静态库"
    mkdir -p "$LIB_OUT_DIR"
    rm -f "$LIB_OUT"
    ARCH_LIBS=""
    for arch in $ARCH_LIST; do ARCH_LIBS="$ARCH_LIBS $WORK/libpikafish-$arch.a"; done
    # shellcheck disable=SC2086
    lipo -create $ARCH_LIBS -output "$LIB_OUT" || die "lipo 合并失败"
fi

[ -s "$LIB_OUT" ] || die "没有产出 $LIB_OUT"
LIB_SIZE="$(wc -c < "$LIB_OUT" | tr -d ' ')"
log "静态库 : $LIB_SIZE 字节"
log "架构   : $(lipo -info "$LIB_OUT" 2>/dev/null | sed 's/.*are: //')"

# 桥接层符号必须在每个架构里都存在（缺一个就说明桥接层没编进去）
MISSING=0
for arch in $ARCH_LIST; do
    for sym in jjpika_start jjpika_stop jjpika_send jjpika_recv jjpika_running; do
        if ! nm -g -arch "$arch" "$LIB_OUT" 2>/dev/null | grep -q " T _${sym}$"; then
            echo "!! [$arch] 静态库里缺符号 _${sym}"
            MISSING=$((MISSING + 1))
        fi
    done
done
if [ "$MISSING" -ne 0 ]; then
    echo "--- 库里前 20 个外部符号（arm64）---"
    nm -g -arch arm64 "$LIB_OUT" 2>/dev/null | grep " T " | head -20
    die "桥接层符号不全（缺 $MISSING 个）"
fi
log "符号齐全: jjpika_start/stop/send/recv/running（arm64 + arm64e）"

# 补丁符号必须在：没有就说明 patch-engine.py 没生效，包里的引擎仍会在
# 网络校验失败时 exit，一搜索就把 App 带走。
for arch in $ARCH_LIST; do
    if ! nm -g -arch "$arch" "$LIB_OUT" 2>/dev/null | grep -q " T _jj_last_network_load_error$"; then
        die "[$arch] 缺 _jj_last_network_load_error —— 引擎补丁没生效"
    fi
done
log "引擎补丁已生效: 网络校验失败不再 exit（jj_last_network_load_error 在）"

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
