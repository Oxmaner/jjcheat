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
        -Wno-deprecated-declarations -Wno-nullability-completeness
        -Wall -Werror -Wuninitialized
        -Wno-unused-variable -Wno-unused-function
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
    echo "!! 没有找到源文件（模块: ${DIRS}）" >&2
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

# ---------------------------------------------------------------------------
# 菜单一致性检查（2.1.80）
#
# 【守的是什么】菜单项的 action 标识与 onMenuItem 的 switch 分支必须一一对应。
# 2.1.78 把「重置开局」插到「HUD」前面时，菜单顺序变了、switch 没跟着改，
# 结果点「HUD」实际执行了「重置开局」——HUD 开关因此完全失灵，而且从代码上看
# 每一行都对，很难靠肉眼发现。
# 现在两边都用 JJMenuAction 枚举，这里做集合比对；另外禁止出现数字下标分支
# （出现就说明又回到了「按下标分派」的老路）。
# ---------------------------------------------------------------------------
CTRL="$TWEAK/Game/JJGameController.m"
menu_fail=0
if [ -f "$CTRL" ]; then
    # 菜单里实际挂上的 action（形如 e3.action = JJMenuActionHUD;）
    assigned="$(sed -n '/- (void)showMenu /,/showMenuWithEntries/p' "$CTRL" \
        | grep -oE '\.action = JJMenuAction[A-Za-z]+' | sed 's/.*= //' | sort -u)"
    # switch 里实际处理的分支
    handled="$(grep -oE 'case JJMenuAction[A-Za-z]+' "$CTRL" | sed 's/case //' | sort -u)"

    if [ -z "$assigned" ]; then
        echo "FAIL  菜单一致性：showMenu 里没有找到任何 action 赋值"
        menu_fail=1
    elif [ "$assigned" != "$handled" ]; then
        echo "FAIL  菜单一致性：菜单项与 switch 分支不匹配"
        echo "      仅菜单有: $(comm -23 <(printf '%s\n' "$assigned") <(printf '%s\n' "$handled") | tr '\n' ' ')"
        echo "      仅 switch 有: $(comm -13 <(printf '%s\n' "$assigned") <(printf '%s\n' "$handled") | tr '\n' ' ')"
        menu_fail=1
    else
        cnt="$(printf '%s\n' "$assigned" | wc -l | tr -d ' ')"
        echo "ok    菜单一致性：$cnt 项 action 与 switch 全对应"
    fi

    # ★ 每条 case 实际调用的方法必须是预期那个。
    #
    # 为什么还需要这一条：只比对「action 集合」抓不到「case 标签对、动作体被换」
    # 这类错位 —— 而那正是 2.1.78 的真实形态（点 HUD 走了 resetToStartPosition，
    # 标签还是 HUD）。所以这里把「动作 → 方法」的对应关系写死，逐条核对。
    check_case() {
        action="$1"; expect="$2"
        # 取该 case 之后 3 行，看有没有调用预期方法
        if grep -A3 "case $action:" "$CTRL" | grep -q "$expect"; then
            return 0
        fi
        echo "FAIL  菜单分派：$action 应调用 $expect"
        grep -A3 "case $action:" "$CTRL" | sed 's/^/      /'
        menu_fail=1
        return 1
    }
    check_case JJMenuActionPlugin          setPluginEnabled
    check_case JJMenuActionAutoCalibrate   autoCalibrate
    check_case JJMenuActionManualCalibrate manualCalibrate
    check_case JJMenuActionHUD             toggleHUD
    check_case JJMenuActionResetBoard      resetToStartPosition
    check_case JJMenuActionThink           showThinkSheet
    check_case JJMenuActionEngineOptions   showEngineOptionsSheet
    check_case JJMenuActionEngineStatus    showEngineStatus

    # 禁止按下标分派（case 0..9 这种）
    if grep -qE 'case [0-9]+:' "$CTRL"; then
        echo "FAIL  菜单一致性：onMenuItem 又出现数字下标分支（应使用 JJMenuAction）"
        grep -nE 'case [0-9]+:' "$CTRL" | sed 's/^/      /'
        menu_fail=1
    fi

    [ "$menu_fail" -eq 0 ] && echo "ok    菜单分派：8 条 action → 方法全部核对通过"
else
    echo "FAIL  菜单一致性：找不到 $CTRL"
    menu_fail=1
fi

echo "----"
echo "通过 $ok 个，失败 $fail 个"
[ "$fail" -eq 0 ] || exit 1
[ "$menu_fail" -eq 0 ] || exit 1
echo "注意：Tweak.x 走 Logos 预处理，本脚本不覆盖，由 CI 的 theos 构建保证。"
