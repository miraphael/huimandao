# -*- coding: utf-8 -*-
"""
GitHub API 增量同步（按 **blob sha** 比对，不依赖 git diff）

## 为什么不用 git diff 做基线
`api_push.py` 用 `git diff <remote_parent>..HEAD`。但远端提交是走 API 建的，
**那个 sha 不在本地对象库里** → 脚本会退回「上一个本地提交」当基线，
基线一错，变更集就错（要么漏推、要么把已推内容重复推一遍）。
`git diff` 也**表达不了「删除」**，配合 XcodeGen 的
`sources: - path: 绘漫岛` 全目录 glob，本地删掉的 .swift 会一直编进 IPA
（实测 `ImageDiskCache.swift` 复活过）。

## 这里的做法
直接用 git 的对象哈希规则算本地每个文件的 blob sha（`--no-filters`，
避免 CRLF→LF 的 clean filter 造成假差异），与远端 tree 里的 sha 逐一比对：
  · sha 不同 → 上传新 blob
  · 远端有、本地无 → `sha=None` 从 tree 移除
  · sha 相同 → 跳过（不产生无谓上传）

这样**无论 git 历史怎么错位，结果都等于「远端 = 本地工作区」**。
"""
import base64
import json
import os
import subprocess
import sys
import urllib.request

TOKEN = open(os.path.expanduser("~/.zcode/gh_token")).read().strip()
REPO = "miraphael/huimandao"
API = f"https://api.github.com/repos/{REPO}"

# 同步范围：项目里所有会被 CI 用到的文件类型（含工程配置与 workflow）
#
# ⚠️ 2026-10-11 补 `Vendor/` 与 `WebResources/`：
#    `project.yml` 里 `- path: Vendor/unrar`（156 个文件，含 83 个 `.cpp` /
#    64 个 `.hpp`）与 `- path: WebResources/web`（css/html/js/ico，作为
#    folder reference 打进 IPA）**都被 CI 使用**，但两者既不满足
#    `INCLUDE_PREFIXES`、扩展名也大多不在 `EXTS` 里 ——
#    于是对这两棵树的任何本地改动**永远不会被推上远端**，CI 用的是旧副本。
#    这与本脚本开头宣称的「远端 = 本地工作区」直接矛盾。
# ⚠️ 2026-10-16 补 `.circleci/`：GitHub Actions 封锁 + Codemagic 402 之后，
#    把免费构建通道迁到 CircleCI（.circleci/config.yml）。
#    同理漏登记 = 配置永远不会上远端，CI 读不到。
INCLUDE_PREFIXES = ("绘漫岛/", ".github/", ".circleci/", "Vendor/", "WebResources/")
# ⚠️ `api_sync.py` 也要放进来 —— 它在**根目录**，既不满足 INCLUDE_PREFIXES，
#    之前也不在这个集合里，所以它自己从来没被同步过（远端那个是早期 git push 留下的）。
#    同类问题：凡是被 CI 或工具链用到的根目录文件都要在这里登记。
# ⚠️ 2026-10-16 补 `azure-pipelines.yml`：Azure Pipelines 备选通道（同 .circleci/）。
# ⚠️ 2026-10-16 移除 `功能对照表.md`：用户在 GitHub 网页端手动删除了它
#    （内容与 `README-构建与安装.md` 的「功能保全对照」表重复）。
#    本地仍保留该文件，但不再推送 —— 尊重远端那次删除，不要把它推回来。
INCLUDE_FILES = {"project.yml", "api_push.py", "api_sync.py", ".gitignore",
                 "codemagic.yaml", "azure-pipelines.yml",
                 "README-构建与安装.md"}
EXTS = (".swift", ".json", ".plist", ".yml", ".yaml", ".py", ".md",
        ".strings", ".ttf", ".otf", ".xcconfig",
        # ⚠️ 2026-10-09 补：**资源文件与桥接文件**之前漏了，后果是
        #    「本地换了 AppIcon、CI 编出来的还是旧图」——
        #    v19 的 `AppIcon60x60@2x.png` 与 v18 **md5 完全相同**、`Assets.car` 也相同，
        #    排查半天才发现本地 1,255,390 B 的新图从来没被推上去（远端还是 449,046 B 的旧图）。
        #    同批被漏的还有 `绘漫岛/Bridging/{HMDBridging.h, rar_wrapper.c, rar_wrapper.h}`。
        #    **教训：凡是被 CI 用到的文件类型都必须在这里；
        #      加完要用「本地文件 ↔ 远端 tree」全量核对一遍，不能只看改动清单。**
        ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".pdf",
        ".h", ".c", ".cpp", ".m", ".mm",
        # ⚠️ 2026-10-11 补：`Vendor/unrar` 用 `.hpp/.cpp`，网页编辑器用
        #    `.css/.js/.html/.ico`，Windows 工程残留 `.def/.rc`。
        ".hpp", ".css", ".js", ".html", ".ico", ".def", ".rc",
        ".xcprivacy", ".stringsdict", ".metal", ".xib", ".storyboard",
        # ⚠️ 2026-10-14 补：`.txt` —— `绘漫岛/Resources/builtin_purge_list.txt`
        #    （老用户清理内置源用的 URL 清单）在 `project.yml` 里显式登记为资源，
        #    但 `.txt` 不在白名单 → **文件没被推上去** → CI 在 `Generate Xcode project`
        #    阶段报 `has a missing source directory` 构建失败。
        #    又一次印证上面那条教训：**凡是被 CI 用到的文件类型都必须在这里**。
        ".txt")


def api(method, path, payload=None):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.urlopen(req, data=data, timeout=90)
    b = r.read()
    return json.loads(b) if b else None


def wanted(path: str) -> bool:
    if path in INCLUDE_FILES:
        return True
    if not path.endswith(EXTS):
        return False
    return any(path.startswith(p) for p in INCLUDE_PREFIXES)


def local_files():
    out = {}
    for dirpath, dirnames, names in os.walk("."):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "build", "ciout", ".zsign", "DerivedData")]
        for n in names:
            full = os.path.join(dirpath, n)
            # ⚠️ 必须用 os.path.relpath —— 手写 `full[2:]` / `startswith("./")`
            #    在 Windows 上会拿到反斜杠路径（`.\绘漫岛\Core\X.swift`），
            #    replace(os.sep,'/') 之后变成 `./绘漫岛/Core/X.swift`，
            #    与远端路径 `绘漫岛/Core/X.swift` **永远对不上** →
            #    每个文件都被判成「新增」，远端每个文件都被判成「删除」。
            #    （这个 bug 真发生过一次，把远端 绘漫岛/ 下的 swift 全删了。）
            rel = os.path.relpath(full, ".").replace(os.sep, "/")
            if rel.startswith("./"):
                rel = rel[2:]
            if wanted(rel):
                out[rel] = full
    return out


def blob_sha(path: str) -> str:
    # --no-filters：不做 CRLF→LF 的 clean filter，否则与远端字节对不上
    return subprocess.check_output(["git", "hash-object", "--no-filters", "--", path]).decode().strip()


# ⚠️ **拒绝看起来像开关的参数**。
#    本脚本没有 `--dry-run`。历史上有人（包括 AI）习惯性执行
#    `python api_sync.py --dry-run` 想看差异 —— 结果是 `--dry-run` 被当成
#    **提交信息**，脚本照常推到远端 main（第一个参数就是 commit message）。
#    这里显式拦下：任何以 `-` 开头的参数都不接受。
#    想看差异请自己跑 `local_files()` 与远端 tree 比对（见文件末尾的说明）。
_extra = [a for a in sys.argv[1:] if a.startswith("-")]
if _extra:
    print(f"❌ 不支持的参数：{_extra}")
    print("   本脚本**没有** --dry-run / --check 之类的开关。")
    print("   唯一的参数是提交信息；想预览差异请手动比对 local_files() 与远端 tree。")
    sys.exit(2)

msg = sys.argv[1] if len(sys.argv) > 1 else subprocess.check_output(
    ["git", "log", "--format=%s", "-1"]).decode().strip()

ref = api("GET", "/git/ref/heads/main")
parent = ref["object"]["sha"]
print("远端 HEAD:", parent[:7])

remote_commit = api("GET", f"/git/commits/{parent}")
base_tree = remote_commit["tree"]["sha"]
tree = api("GET", f"/git/trees/{base_tree}?recursive=1")
remote = {e["path"]: e["sha"] for e in tree["tree"] if e["type"] == "blob"}
print("远端 blob:", len(remote))

local = local_files()
print("本地候选:", len(local))

# ── 前缀自检（2026-10-16 加）：防止「目录改名后白名单没跟着改」──────────
#    真实事故：源码目录改过一次名，但 INCLUDE_PREFIXES 里还写着旧目录名，
#    于是 (a) 新目录下的 109 个 .swift **永远推不上去**；
#    (b) 远端旧目录被当成「本地已删」整棵删掉 —— 远端一度 0 个 .swift，
#    CI 拿到的是没有源码的空壳工程。教训：**前缀必须等于当前真实目录名**。
#    这里对每个前缀做存在性检查：本地匹配不到、而远端还有该前缀的文件 → 直接中止。
for _p in INCLUDE_PREFIXES:
    if not any(rel.startswith(_p) for rel in local):
        n_remote = sum(1 for rp in remote if rp.startswith(_p))
        print(f"⚠️  白名单前缀 {_p!r} 在本地匹配不到任何文件（目录是否已改名？）")
        if n_remote:
            print(f"🛑 中止：远端仍有 {n_remote} 个文件位于 {_p!r} 下，继续会把它们整棵删除。"
                  f"请先把 INCLUDE_PREFIXES 改成当前目录名。")
            raise SystemExit(2)

entries = []
changed, added, deleted, same = [], [], [], 0
for rel, full in sorted(local.items()):
    sha = blob_sha(full)
    if rel not in remote:
        added.append(rel)
    elif remote[rel] != sha:
        changed.append(rel)
    else:
        same += 1
        continue
    content = open(full, "rb").read()
    b = api("POST", "/git/blobs",
            {"content": base64.b64encode(content).decode(), "encoding": "base64"})
    entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": b["sha"]})

for rel in sorted(remote):
    if rel not in local and wanted(rel):
        deleted.append(rel)
        entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": None})

print(f"\n新增 {len(added)} / 修改 {len(changed)} / 删除 {len(deleted)} / 未变 {same}")
for p in added:
    print("  + ", p)
for p in changed:
    print("  ~ ", p)
for p in deleted:
    print("  - ", p)

# ── 安全闸：路径解析一旦出错，就会「删光远端 + 全量重加」 ──────────────
# 这里做一次不变量检查：删除数不该超过远端该类型文件的一半。
# 真删文件是少数派；一旦大面积「删除」，几乎一定是路径 bug，直接中止。
scoped_remote = [p for p in remote if wanted(p)]
if scoped_remote and len(deleted) > max(3, len(scoped_remote) // 2):
    print(f"\n🛑 中止：要删除 {len(deleted)} 个，但远端受管文件只有 {len(scoped_remote)} 个 —— "
          f"这不像真的删除，更像路径解析出错（相对路径/分隔符 bug）。")
    print("   未做任何改动。请先核对 local_files() 输出的路径形态。")
    raise SystemExit(2)

if not entries:
    print("\n远端已与本地一致，无需提交")
    raise SystemExit(0)

new_tree = api("POST", "/git/trees", {"base_tree": base_tree, "tree": entries})
commit = api("POST", "/git/commits",
             {"message": msg, "tree": new_tree["sha"], "parents": [parent]})
req = urllib.request.Request(API + "/git/refs/heads/main", method="PATCH")
req.add_header("Authorization", f"Bearer {TOKEN}")
req.add_header("Accept", "application/vnd.github+json")
urllib.request.urlopen(req, data=json.dumps({"sha": commit["sha"]}).encode(), timeout=90)
print("\n✅ 已推送:", commit["sha"][:7], "|", msg[:60])
