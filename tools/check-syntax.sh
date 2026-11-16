#!/usr/bin/env bash
# ============================================================
#  JJCheat 本机语法检查
#
#  Windows/Linux 上跑，用本地 LLVM clang + iPhoneOS SDK 对全部 .m/.c 做
#  -fsyntax-only。只查「能不能编译」，不产出 .o、不链接、不打包。
#  真机产物一律由 GitHub Actions 的 theos 构建负责。
#
#  用法:
#    tools/check-syntax.sh            # 检查全部源文件
#    tools/check-syntax.sh Engine     # 只检查某个模块目录
#
#  环境变量:
#    CLANG    clang 路径（默认自动查找）
#    SDK      iPhoneOS SDK 路径（默认 theos-sdks/iPhoneOS16.5.sdk）
# ============================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TWEAK="$ROOT/ios/tweak"
STUB="$ROOT/tools/stub-include"

find_clang() {
    if [ -n "${CLANG:-}" ] && [ -x "$CLANG" ]; then echo "$CLANG"; return; fi
    for c in clang /c/Program\ Files/LLVM/bin/clang.exe /usr/bin/clang /usr/local/opt/llvm/bin/clang; do
        [ -x "$c" ] && { echo "$c"; return; }
    done
    command -v clang 2>/dev/null
}

CLANG_BIN="$(find_clang)"
if [ -z "$CLANG_BIN" ]; then
    echo "!! 找不到 clang，设置 CLANG=/path/to/clang 后重试" >&2
    exit 2
fi

SDK_PATH="${SDK:-}"
if [ -z "$SDK_PATH" ]; then
    for s in "$ROOT/../theos-sdks/iPhoneOS16.5.sdk" \
             "$ROOT/../theos-sdks/iPhoneOS15.6.sdk"; do
        [ -d "$s" ] && { SDK_PATH="$s"; break; }
    done
fi
if [ -z "$SDK_PATH" ] || [ ! -d "$SDK_PATH" ]; then
    echo "!! 找不到 iPhoneOS SDK，设置 SDK=/path/to/iPhoneOS.sdk 后重试" >&2
    exit 2
fi

INCS="-I$TWEAK/include"
for m in Core Capture Vision Engine Game UI; do
    INCS="$INCS -I$TWEAK/$m"
done

CFLAGS="-fsyntax-only -target arm64-apple-ios15.0 -isysroot $SDK_PATH
        -fobjc-arc -fblocks -std=gnu11 -DTHEOS_PACKAGE_SCHEME_ROOTHIDE
        -Wno-deprecated-declarations -Wno-unused-variable -Wno-nullability-completeness
        -Wno-error=int-to-void-pointer-cast -Wno-error=void-pointer-to-int-cast
        -I$STUB"

MODULES="${1:-}"
if [ -n "$MODULES" ]; then
    DIRS="$MODULES"
else
    DIRS="Core Capture Vision Engine Game UI"
fi

FILES=""
for d in $DIRS; do
    for f in "$TWEAK/$d"/*.m "$TWEAK/$d"/*.c; do
        [ -f "$f" ] && FILES="$FILES $f"
    done
done

if [ -z "$FILES" ]; then
    echo "!! 没有找到源文件（模块: $DIRS）" >&2
    exit 2
fi

echo "clang : $CLANG_BIN"
echo "sdk   : $SDK_PATH"
echo "----"

fail=0
ok=0
for f in $FILES; do
    rel="${f#$TWEAK/}"
    # shellcheck disable=SC2086
    out="$("$CLANG_BIN" $CFLAGS $INCS "$f" 2>&1)"
    # 过滤掉 SDK 内部头文件自身的告警，只看我们自己的文件
    errs="$(printf '%s\n' "$out" | grep -E 'error:' | grep -v "$SDK_PATH" || true)"
    if [ -n "$errs" ]; then
        echo "FAIL  $rel"
        printf '%s\n' "$errs" | sed 's/^/      /'
        fail=$((fail + 1))
    else
        echo "ok    $rel"
        ok=$((ok + 1))
    fi
done

echo "----"
echo "通过 $ok 个，失败 $fail 个"
[ "$fail" -eq 0 ] || exit 1
echo "注意：Tweak.x 走 Logos 预处理，本脚本不覆盖，由 CI 的 theos 构建保证。"
