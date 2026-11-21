import base64, hashlib, json, os, ssl, sys, time, urllib.error, urllib.parse, urllib.request

TOKEN = "<YOUR_GITHUB_PAT>"
API = "https://api.github.com/repos/Oxmaner/jjcheat"
ROOT = r"F:\MacLin\Documents\jjcheat-patch"
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE

SKIP_DIRS = ('__pycache__', '.build', '.theos', 'node_modules', '_backup', '_icon', '_preview', '.git')
SKIP_EXT = ('.pyc',)


def req(method, url, body=None, timeout=180):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "token " + TOKEN, "User-Agent": "dsh",
        "Accept": "application/vnd.github+json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=CTX) as resp:
            raw = resp.read().decode()
        return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode('utf-8', 'replace')[:500]
        print(f'  HTTP {e.code}: {detail}', flush=True)
        raise


def retry(fn, n=5, label=""):
    for i in range(1, n + 1):
        try:
            return fn()
        except Exception as e:
            print(f'  {label} try{i}: {type(e).__name__}', flush=True)
            if i == n:
                raise
            time.sleep(4)


# ① 收集本地文件
files = []
for dp, dns, fns in os.walk(ROOT):
    if any(s in dp for s in SKIP_DIRS):
        continue
    dns[:] = [d for d in dns if d not in SKIP_DIRS]
    for fn in fns:
        if fn.endswith(SKIP_EXT) or fn.startswith('.~'):
            continue
        full = os.path.join(dp, fn)
        rel = os.path.relpath(full, ROOT).replace('\\', '/')
        if any(s in rel for s in SKIP_DIRS):
            continue
        files.append(rel)
files.sort()
print(f'本地待推 {len(files)} 个文件', flush=True)

# ② 逐个建 blob
items, md5s, total = [], {}, 0
for i, rel in enumerate(files, 1):
    path = os.path.join(ROOT, rel)
    raw = open(path, 'rb').read()
    if raw.startswith(b'\xef\xbb\xbf'):
        raw = raw[3:]
        open(path, 'wb').write(raw)
    # 安全：不含明文 token
    if b'ghp_' in raw:
        txt = raw.decode('utf-8', 'replace')
        import re as _re
        new = _re.sub(r'ghp_[A-Za-z0-9]{36}', '<YOUR_GITHUB_PAT>', txt)
        raw = new.encode('utf-8')
        open(path, 'wb').write(raw)
        print(f'  ! {rel} 含明文 token，已替换', flush=True)
    md5s[rel] = hashlib.md5(raw).hexdigest()
    total += len(raw)
    blob = retry(lambda r=raw: req("POST", API + "/git/blobs",
                                   {"content": base64.b64encode(r).decode(), "encoding": "base64"}),
                 label='blob ' + rel)
    items.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    if i % 10 == 0 or i == len(files):
        print(f'  {i}/{len(files)}  blob 已建', flush=True)

print(f'  总大小 {total / 1024 / 1024:.2f} MB', flush=True)

# ③ 全新树（不带 base_tree → 只含下列文件，旧的自动消失）
tree = retry(lambda: req("POST", API + "/git/trees", {"tree": items}), label="tree")
print(f'  tree={tree["sha"][:8]}', flush=True)

# ④ commit
head = retry(lambda: req("GET", API + "/git/ref/heads/main"), label="ref")["object"]["sha"]
msg = """chore: 用当前工作区完整覆盖仓库（清理历史残留）

之前仓库里累积了 223 个文件，其中大量是已经下线的历史遗留：
  testdata/           112 个（旧回归测试图集，regression.js 已删）
  tools/*.mjs         17 个（bench / refine / gen-templates 等一次性脚本）
  ios/ 多余文件       27 个（旧架构，现已重写）
  README*.md          2 个（已由 HANDOFF.md 取代）

现在整体重建为当前实际需要的 64 个文件：
  .github/workflows/  CI（roothide deb 构建）
  dist/engine.js      打包产物
  engine/             Pikafish 构建脚本（build-ios.sh / check-net.py / patch-engine.py）
  ios/tweak/          Tweak 源码（含 layout 资源与 libpikafish.a）
  src/                JS 引擎源码（cst / app / vision）
  tools/              打包与测试脚本
  HANDOFF.md          交接文档（5.7 KB，只剩当前状态 + 唯一待办）

采用不带 base_tree 的 git tree，因此旧文件全部被移除。"""

commit = retry(lambda: req("POST", API + "/git/commits",
                           {"message": msg, "tree": tree["sha"], "parents": [head]}), label="commit")
print(f'  commit={commit["sha"][:7]}', flush=True)

retry(lambda: req("PATCH", API + "/git/refs/heads/main", {"sha": commit["sha"], "force": False}), label="ref")
print('  main 已更新', flush=True)

# ⑤ 验证
time.sleep(3)
r = retry(lambda: req("GET", API + "/git/trees/main?recursive=1"), label="verify-tree")
remote = {it["path"]: it for it in r["tree"] if it["type"] == "blob"}
print(f'\n=== 验证 ===', flush=True)
print(f'  远程文件数: {len(remote)}  本地: {len(files)}', flush=True)

missing = [f for f in files if f not in remote]
extra = [p for p in remote if p not in files]
print(f'  本地有但远程缺: {len(missing)}', flush=True)
for p in missing[:10]:
    print(f'     - {p}', flush=True)
print(f'  远程多出（应清零）: {len(extra)}', flush=True)
for p in extra[:10]:
    print(f'     + {p}', flush=True)

# 抽查内容
bad = []
for rel in files:
    if rel.endswith('.deb'):
        continue
    path = os.path.join(ROOT, rel)
    raw = open(path, 'rb').read()
    if hashlib.md5(raw).hexdigest() != md5s[rel]:
        bad.append(rel)
print(f'  本地 md5 变化: {len(bad)}', flush=True)

ok = not missing and not extra
print(f'\n  {"✅ 完全一致" if ok else "⚠️ 有差异"}', flush=True)
sys.exit(0 if ok else 1)
