#!/usr/bin/env bash
# ============================================================
#  Pikafish iOS 交叉编译
#
#  必须在 macOS 上跑（需要 Xcode 的 iPhoneOS SDK + Apple ld64 + ldid）。
#  本机 Windows 只能做语法检查，这一环永远交给 GitHub Actions 的 macos-15。
#
#  产物：
#    ios/tweak/layout/Library/Application Support/JJCheat/Pikafish/pikafish
#    已 ad-hoc 签名（ldid -S），可直接被 tweak 用 posix_spawn 拉起
#
#  用法:
#    engine/build-ios.sh                 # 默认 tag + 默认输出
#    PIKA_TAG=master engine/build-ios.sh # 试最新 master
#    PIKA_FORCE=1 engine/build-ios.sh    # 忽略缓存重编
#
#  为什么不用官方 Makefile 的 macos 目标：
#    它在 TARGET_KERNEL=Darwin 时会往 CXXFLAGS 里塞 -mmacosx-version-min=10.15，
#    和我们的 -target arm64-apple-ios14.0 直接冲突。Makefile 里那是普通赋值，
#    命令行变量优先级更高，所以传 mac_target_flags="" 就能干净地屏蔽掉。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${PIKA_TAG:-Pikafish-2026-09-06}"
REPO="${PIKA_REPO:-https://github.com/official-pikafish/Pikafish.git}"
WORK="$ROOT/engine/.build"
SRC="$WORK/src"
MIN_IOS="${PIKA_MIN_IOS:-14.0}"
NFORCE="${PIKA_FORCE:-0}"
DEST_DIR="$ROOT/ios/tweak/layout/Library/Application Support/JJCheat/Pikafish"
DEST="$DEST_DIR/pikafish"
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
# 官方 build 目标会自己跑 net.sh，但先跑一遍能让「下载失败」和「编译失败」分开报错。
if [ ! -f pikafish.nnue ]; then
    log "下载 NNUE 网络（约 30~60MB）"
    sh ../scripts/net.sh || die "NNUE 下载失败（GitHub Releases 不通？）"
else
    log "复用已有 NNUE: $(wc -c < pikafish.nnue | tr -d ' ') 字节"
fi
[ -s pikafish.nnue ] || die "pikafish.nnue 是空的"

# ---------- 编译 ----------
if [ -f pikafish ] && [ "$NFORCE" != "1" ] && [ pikafish -nt pikafish.nnue ]; then
    log "已存在可执行文件且比网络新，跳过编译（PIKA_FORCE=1 可强制重编）"
else
    JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    log "编译中（-j${JOBS}，LTO 首次约 8~15 分钟）"
    # CXXFLAGS/LDFLAGS 走环境变量：Makefile 在 MAKELEVEL=0 时把它们存进 ENV_*，
    # 命令行传同名变量会被它的赋值覆盖掉。
    if ! env CXXFLAGS="$TARGET_FLAGS" LDFLAGS="$TARGET_FLAGS" \
         make -j"$JOBS" build \
              ARCH=armv8 COMP=clang CXX="$CLANGXX" \
              mac_target_flags="" 2>&1 | tee "$WORK/build.log"; then
        die "编译失败，日志: $WORK/build.log"
    fi
    [ -f pikafish ] || die "编译结束但没有产出 pikafish"
fi

# ---------- 校验 ----------
# 注意：Pikafish 2026 版不再把 NNUE 编进二进制（network.cpp 无 INCBIN，
# 只在 {cwd, 二进制目录} 里找 pikafish.nnue），所以可执行文件只有 ~800KB，
# 权重是单独一个 ~48MB 的文件，两个都必须随包走。
log "校验产物"
FILEINFO="$(file -b pikafish)"
echo "    $FILEINFO"
case "$FILEINFO" in
    *Mach-O*arm64*) ;;
    *) die "产物不是 arm64 Mach-O：$FILEINFO" ;;
esac
[ -s pikafish.nnue ] || die "缺 pikafish.nnue"
NET_SIZE="$(wc -c < pikafish.nnue | tr -d ' ')"
[ "$NET_SIZE" -gt 20000000 ] || die "pikafish.nnue 只有 $NET_SIZE 字节，下载不完整"
log "权重   : $NET_SIZE 字节"

# ---------- 签名 ----------
# 放在量体积之前：ldid 会往 Mach-O 里追加签名段（约 10KB），
# 先量后签会让日志里的数字和 deb 里的实际大小对不上。
if command -v ldid >/dev/null; then
    ldid -S pikafish
    log "已 ad-hoc 签名（ldid -S）"
else
    log "没有 ldid，改用 codesign -s - 兜底"
    codesign -f -s - pikafish
fi
codesign -dv pikafish 2>&1 | sed 's/^/    /' || true

SIZE="$(wc -c < pikafish | tr -d ' ')"
log "可执行 : $SIZE 字节（含签名）"

# ---------- 落盘 ----------
mkdir -p "$DEST_DIR"
cp -f pikafish "$DEST"
cp -f pikafish.nnue "$DEST_NET"
chmod 0755 "$DEST"
chmod 0644 "$DEST_NET"
log "已放置: $DEST  +  $DEST_NET"
log "sha256(bin): $(shasum -a 256 "$DEST" | cut -d' ' -f1)"
log "sha256(net): $(shasum -a 256 "$DEST_NET" | cut -d' ' -f1)"
echo
echo "下一步：cd ios/tweak && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide"
