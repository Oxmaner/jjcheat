# JJCheat · roothide 适配版

上游工程：[lichengyang51/jjcheat](https://github.com/lichengyang51/jjcheat) → `ios/tweak/`（越狱 Tweak 路线）

本仓库做 **roothide 适配 + 云编译**。1.0.1 时源码零改动；1.0.2 起只动了 `JJEngineBridge.m` 的**一处路径候选**（`locateEngineScript`，见第二节），`Tweak.xm / JJController.m / JJScreenGrabber.m / JJHUDWindow.m` 仍与上游完全一致。

- 设备：iPhone 13 Pro Max / iOS 15.1 / **roothide 越狱**（Bootstrap）
- 目标 App Bundle ID：`cn.jj.chinachess`
- 产物：`com.fujiang.jjcheat_1.0.2_iphoneos-arm64e.deb`

---

## 一、适配改了什么

| 位置 | 改动 | 原因 |
|---|---|---|
| `ios/tweak/Makefile` | 新增 `THEOS_PACKAGE_SCHEME = roothide` | roothide 的 dylib 必须用 `@loader_path/.jbroot/...` 作为 install_name；没有这一行编出来的包在 roothide 上 dyld 直接找不到依赖 |
| `ios/tweak/Makefile` | `THEOS_PACKAGE_SCHEME=roothide` 时 `JJCheat_LIBRARIES = roothide` | 让 `jbroot()` 链到 `libroothide.dylib`（install-name `@loader_path/.jbroot/usr/lib/libroothide.dylib`） |
| `ios/tweak/Makefile` | `TARGET := iphone:clang:16.5:14.0`（沿用上游）+ 保留 `-I$(THEOS_PROJECT_DIR)/include` | CI 里补了 theos 的 16.5 SDK，和上游编译环境一致；`include/IOSurface` 是手写的最小私有头（iOS SDK 只有二进制没有头文件） |
| `ios/tweak/Makefile` | `-Wno-error=int-to-void-pointer-cast` | Xcode 16 的 clang 把 `(void *)s_serverPort` 这类转换当 error，降级为 warning |
| `ios/tweak/Makefile` | `DISABLE_ROOTLESS_COMPAT_WARNING = 1` | 消掉 roothide/theos 的 rootless 兼容告警（本工程不用 `/var/jb` 宏） |
| `ios/tweak/JJEngineBridge.m` | 加 `#import <roothide.h>`；`locateEngineScript` 加 `jbroot(...)` 首选候选 + 命中日志 | 见第二节 |
| `ios/tweak/control` | `Architecture: iphoneos-arm64e`，`Version: 1.0.2` | roothide 的包架构名；版本号区分上游 rootful 包 |
| `ios/tweak/JJCheat.plist` | 过滤列表加入 `cn.jj.chinachess` | 你的 JJ象棋 实际包名 |
| `ios/tweak/layout/DEBIAN/postinst` + `layout/usr/bin/jjcheat-fix` | 新增 | engine.js 的 `.app` 兜底；modern theos 只从 `layout/DEBIAN/` 收维护脚本 |
| `ios/tweak/layout/DEBIAN/prerm` | 新增 | 卸载时把塞进 .app 的 engine.js 撤掉 |
| `.github/workflows/build-roothide-deb.yml` | 新增 | macOS runner + roothide/theos 云编译 |

引擎内核 `src/` 与打包器 `tools/bundle.js` 原样搬过来，CI 里用 `node tools/bundle.js` 生成 `dist/engine.js`（这一步是上游原有流程）。

---

## 二、roothide 上最关键的坑：engine.js 路径

1.0.2 起 `locateEngineScript` 的候选顺序（命中哪条都会打日志）：

| # | 路径 | 适用环境 | 说明 |
|---|---|---|---|
| ① | `jbroot(@"/Library/Application Support/JJCheat/engine.js")` | roothide | 返回 `<jbroot>/Library/...`，deb 里那份直接命中；**不受 App 更新、注入开关关开影响** |
| ② | `/var/jb/Library/Application Support/JJCheat/engine.js` | rootless | 固定前缀 |
| ③ | `/Library/Application Support/JJCheat/engine.js` | rootful | 上游原始值 |
| ④ | `[[NSBundle mainBundle] pathForResource:@"engine" ofType:@"js"]` | 兜底 | `postinst` / `jjcheat-fix` 写进目标 `.app` 的那份 |

roothide 把越狱根（jbroot）随机化到 `/var/containers/Bundle/Application/.jbroot-XXXXXXXX/`，
所以 ② ③ 在 roothide 上必然 `ENOENT`（Foundation 拿字面量去查系统根目录）。① 用 `jbroot()` 在运行时解析，
是 RootHide 官方指定的做法（`jbroot()` 由 libroothide 提供，靠自身加载路径反推 jbroot）。

① 命中不了时（比如 `libroothide` 解析失败、或换了构建方案），会自动落到 ④：
`postinst` 安装时扫 `/rootfs/var/containers/Bundle/Application/*/*.app`，按 `Info.plist` 的 bundle id 匹配后写入；
App Store 更新会把 `.app` 换掉，重跑即可：

```sh
jjcheat-fix        # 越狱 shell（NewTerm / SSH），root 身份
jjcheat-fix -v     # 看扫描过程
```

`.app` 里只多一个 `engine.js`（0644），不动可执行文件与 Info.plist；卸载时 `prerm` 会删掉（仅当内容与本包一致）。

---

## 三、云编译

仓库 → **Actions** → 左侧 `build-roothide-deb` → **Run workflow**（`main` 分支）。

流水线做的事：

1. `git clone --recursive https://github.com/roothide/theos.git`（**必须是 roothide 版 theos**，官方 theos 没有 `roothide` 打包方案）
2. `brew install ldid dpkg`
3. `node tools/bundle.js` → 写入 `ios/tweak/layout/Library/Application Support/JJCheat/engine.js`
4. `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide`
   - `dpkg-deb` 用包装脚本加 `--root-owner-group`（macOS 没有 fakeroot，否则包内属主会是 runner 用户）
   - 压缩用 `xz`（设备端 dpkg/Sileo 都吃，比 lzma 稳）
5. 校验：解包检查 `JJCheat.dylib` / `JJCheat.plist` / `engine.js` / `jjcheat-fix`，
   `otool -D` 确认 install_name 是 `@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/JJCheat.dylib`
6. 产物：`JJCheat-roothide-deb` artifact + Release 附件（手机浏览器直接下 deb 最省事）

---

## 四、安装

1. **Bootstrap → App List → 打开 JJ象棋（cn.jj.chinachess）的注入开关**（roothide 默认不注入任何第三方 App，这步不做 Tweak 根本不会加载）
2. 装 deb：Sileo/Zebra 点开安装；或 Filza 点 deb 选 Install；或命令行
   ```sh
   dpkg -i com.fujiang.jjcheat_1.0.2_iphoneos-arm64e.deb
   ```
3. `postinst` 会自动把 engine.js 写进 `.app`（`.app` 只当兜底用，正常情况下引擎走 `jbroot()` 那份）
4. 完全退出 JJ象棋再启动（必要时 `killall -9 SpringBoard`）

## 五、验证 / 排错

```sh
# 0) 一次看全：注入 + 路径命中 + 抓帧
log stream --predicate 'eventMessage CONTAINS "[JJCheat]"' --style compact
```

启动游戏后，日志应该依次出现：

```
[JJCheat] tweak 已加载 (pid=...)
[JJCheat] engine.js 未命中: /var/containers/Bundle/Application/.jbroot-XXXXXXXX/Library/Application Support/JJCheat/engine.js   ← 不该出现
[JJCheat] engine.js 命中: /var/containers/Bundle/Application/.jbroot-XXXXXXXX/Library/Application Support/JJCheat/engine.js   ← ① 命中（正常）
[JJCheat] engine.js 加载成功
[JJCheat] CARenderServer: render=... port=... usable=1
```

排错对照：

| 现象 | 结论 / 处理 |
|---|---|
| 连 `[JJCheat] tweak 已加载` 都没有 | dylib 没被注入：Bootstrap App List 开关没开，或 `libroothide` 依赖解析失败（装回 1.0.1 可确认） |
| 只有 `未命中` 的 ①②③，最后 `命中: .../<App>.app/engine.js` | `jbroot()` 那条没生效，走的是 `.app` 兜底 —— 功能可用，但 App 更新后要重跑 `jjcheat-fix` |
| 四条全 `未命中` + `找不到 engine.js` | 跑 `jjcheat-fix -v`，确认 App 已安装、bundle id 匹配 |
| 引擎加载成功但识别乱 | 四点标定没做（上游逻辑：进棋盘界面后标定一次，结果存 `NSUserDefaults`） |
| 游戏白屏/闪退 | `rm <App>.app/engine.js` 恢复原状；只影响兜底那份，`jbroot` 那份可用 `dpkg -i` 重装 |

## 六、卸载

```sh
dpkg -r com.fujiang.jjcheat
```
`prerm` 会删掉注入的 `engine.js`；`/Library/Application Support/JJCheat/` 与偏好设置可用 `jjcheat` 相关 key 手动清。
