#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 dist/engine.js 转成 C 数组，编进 dylib（方案 B 的兜底副本）。

用法: python3 tools/gen-engine-c.py <engine.js> <out.c> <out.h>

为什么要内嵌：roothide 的 jbroot 每次越狱都换随机路径，而且注入到第三方 App 的
dylib 读 jbroot 路径受 App 沙箱约束（jbroot 在 /var/containers/Bundle/Application/
之下，跨 App 容器目录通常读不了）。内嵌一份以后，引擎不再依赖任何文件路径。
"""
import os
import sys


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    src_path, out_c, out_h = sys.argv[1:4]

    data = open(src_path, "rb").read()
    data.decode("utf-8")  # 必须是合法 UTF-8，运行时按 UTF-8 还原成 NSString

    with open(out_h, "w", encoding="utf-8", newline="\n") as f:
        f.write(
            "//\n"
            "//  JJEngineScript.h\n"
            "//  JJCheat —— engine.js 的内嵌副本（由 tools/gen-engine-c.py 生成，勿手改）\n"
            "//\n"
            "//  运行时优先读文件（App 容器 / jbroot / App bundle），都读不到时用这份。\n"
            "//\n"
            "#ifndef JJEngineScript_h\n"
            "#define JJEngineScript_h\n"
            "\n"
            "extern const unsigned char JJEngineScript[];\n"
            "extern const unsigned long JJEngineScriptLength;\n"
            "\n"
            "#endif /* JJEngineScript_h */\n"
        )

    lines = [
        "// generated from %s —— 由 tools/gen-engine-c.py 生成，不要手工编辑" % os.path.basename(src_path),
        '#include "JJEngineScript.h"',
        "",
        "const unsigned char JJEngineScript[] = {",
    ]
    for i in range(0, len(data), 16):
        lines.append("  " + ",".join("0x%02x" % b for b in data[i:i + 16]) + ",")
    lines.append("};")
    lines.append("")
    lines.append("const unsigned long JJEngineScriptLength = %d;" % len(data))
    lines.append("")

    with open(out_c, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))

    print("engine.js %d B -> %s (%d B)" % (len(data), out_c, os.path.getsize(out_c)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
