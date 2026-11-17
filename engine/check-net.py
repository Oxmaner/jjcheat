#!/usr/bin/env python3
# ============================================================
#  NNUE 权重指纹护栏
#
#  为什么需要：
#    Pikafish 的 scripts/net.sh 从
#      https://github.com/official-pikafish/Networks/releases/download/master-net/pikafish.nnue
#    拉权重 —— 那是个**滚动发布**，而本仓库的源码钉在固定 tag
#    （engine/build-ios.sh 的 PIKA_TAG）。两者一旦不同步，就会出现
#    「文件在、大小对、format Version 也对，但架构哈希不符」的情况，
#    而 Pikafish 对这种情况的原生反应是 Network::verify() 里的
#    exit(EXIT_FAILURE)，历史上表现为「HUD 显示思考中 → 整个 App 闪退」。
#
#  所以把权重 sha256 钉进 workflow：官方换网络时构建立刻变红，
#  而不是等到真机上闪退才发现。
#
#  确认新权重可用之后，把 workflow 里的 PIKA_NET_SHA256 更新成新值。
#
#  用法: check-net.py <pikafish.nnue> [--expect <sha256>]
#        （EOFK 环境变量 PIKA_NET_SHA256 也可以，--expect 优先）
# ============================================================
import hashlib
import os
import pathlib
import sys

# format Version 与我们构建所用源码版本的一致性只能运行时确认（Version 在
# zstd 压缩流内部，构建机上不一定有解压工具），所以这里只做「文件指纹」，
# 即「同一份文件」的强保证。架构哈希由引擎自己打印：
#   info string JJ-NNUE FAIL reason=architecture hash mismatch ... fileHash=… engineHash=…
MIN_SIZE = 20_000_000  # 官方网络 ~50MB；小于这个值一定是下载截断


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    expect = ""
    if "--expect" in sys.argv:
        i = sys.argv.index("--expect")
        if i + 1 < len(sys.argv):
            expect = sys.argv[i + 1].strip().lower()
    expect = expect or os.environ.get("PIKA_NET_SHA256", "").strip().lower()

    if not args:
        print("用法: check-net.py <pikafish.nnue> [--expect <sha256>]", file=sys.stderr)
        return 2

    path = pathlib.Path(args[0])
    if not path.is_file():
        print(f"!! 权重不存在: {path}", file=sys.stderr)
        return 1

    data = path.read_bytes()
    size = len(data)
    sha = hashlib.sha256(data).hexdigest()
    head = data[:4].hex()

    print(f"[jj-net] path   = {path}")
    print(f"[jj-net] size   = {size}")
    print(f"[jj-net] sha256 = {sha}")
    print(f"[jj-net] head   = {head} (28b52ffd = zstd 压缩网络，正常)")

    if size < MIN_SIZE:
        print(f"!! 权重只有 {size} 字节（< {MIN_SIZE}），下载不完整", file=sys.stderr)
        return 1

    if head != "28b52ffd":
        print(f"!! 权重不是 zstd 帧（头 {head}）。这个版本只接受压缩网络，"
              f"非压缩文件会在 read_compressed_nnue 里解压失败 → 网络加载不上", file=sys.stderr)
        return 1

    if not expect:
        print("[jj-net] 未提供期望指纹（PIKA_NET_SHA256），跳过比对")
        return 0

    if sha != expect:
        print("", file=sys.stderr)
        print("!! 权重指纹变了 —— 构建拒绝继续", file=sys.stderr)
        print(f"   期望: {expect}", file=sys.stderr)
        print(f"   实际: {sha}", file=sys.stderr)
        print("", file=sys.stderr)
        print("   scripts/net.sh 拉的是滚动发布 master-net，而源码钉在 PIKA_TAG。", file=sys.stderr)
        print("   官方换网络后，新权重可能与本源码的架构哈希不符，真机表现就是", file=sys.stderr)
        print("   「HUD 思考中 → 闪退」（Network::verify 里 exit）。", file=sys.stderr)
        print("   确认新版可用（看 info string NNUE evaluation using ...）之后，", file=sys.stderr)
        print("   把 workflow 的 PIKA_NET_SHA256 更新为上面的实际值。", file=sys.stderr)
        return 1

    print("[jj-net] 指纹一致 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
