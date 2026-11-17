#!/usr/bin/env python3
# ============================================================
#  NNUE 权重指纹护栏
#
#  为什么需要：
#    权重不再是"构建时从网上拉"，而是**随本仓库提交**的 engine/pikafish.nnue
#    （从该 tag 的官方发布包 Pikafish.<tag>.7z 里原样取出，架构哈希与源码一致）。
#    这里守两道门：文件形态（zstd 帧）与 sha256 指纹。
#
#    背景（2026-11-17 真机实测）：官方 scripts/net.sh 拉的滚动发布 master-net
#    是"最新架构"的网络，与钉住的 PIKA_TAG 不配套 ——
#      Pikafish-2026-09-06 的 engineHash = 0x40C70FA6
#      master-net 的 fileHash           = 0xCACA41C8
#    而 Pikafish 对架构不符的原生反应是 Network::verify 里 exit(EXIT_FAILURE)，
#    进程内引擎会把宿主 App 一起杀掉（「HUD 思考中 → 闪退」的真因）。
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
MIN_SIZE = 3_000_000  # 配套网络 zstd 后约 4.19MB（解压 5.5MB）；更小一定是截断


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
