# -*- coding: utf-8 -*-
# 通过 GitHub API 推送本地提交（git push 不通时的备用通道）
import json, os, base64, urllib.request, subprocess

TOKEN = open(os.path.expanduser('~/.zcode/gh_token')).read().strip()
REPO = 'miraphael/huimandao'
API = f'https://api.github.com/repos/{REPO}'

def api(method, path, payload=None):
    req = urllib.request.Request(API + path, method=method)
    req.add_header('Authorization', f'Bearer {TOKEN}')
    req.add_header('Accept', 'application/vnd.github+json')
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.urlopen(req, data=data, timeout=60)
    b = r.read()
    return json.loads(b) if b else None

remote = api('GET', '/git/ref/heads/main')
parent = remote['object']['sha']
print('远程 HEAD:', parent)

log = subprocess.check_output(['git', 'log', '--format=%H %s', '-1']).decode().strip()
local_sha, msg = log.split(' ', 1)
print('本地 HEAD:', local_sha[:7], '|', msg[:50])
if local_sha.startswith(parent[:7]):
    print('远程已是最新'); raise SystemExit

# 尝试常规 diff；若 parent 不是本地对象则退回"上一个本地提交"作 diff 基线
try:
    diff = subprocess.check_output(['git', 'diff', '--name-only', parent + '..HEAD']).decode().split()
except Exception:
    prev = subprocess.check_output(['git', 'log', '--format=%H', '-2']).decode().split()[1]
    print('parent 非本地对象，diff 基线:', prev[:7])
    diff = subprocess.check_output(['git', 'diff', '--name-only', prev + '..HEAD']).decode().split()

print('变更文件:', len(diff))
remote_commit = api('GET', f'/git/commits/{parent}')
base_tree = remote_commit['tree']['sha']

entries = []
for f in diff:
    path = f.replace(chr(92), '/')
    if not os.path.exists(f):
        # ⚠️ 本地已删除的文件：必须用 sha=None 从远端 tree 移除。
        #    旧版直接 continue，导致「本地删了、远端还在」——
        #    因为 XcodeGen 是 `sources: - path: 绘漫岛` 全目录 glob，
        #    残留的 .swift 会被继续编进 IPA（实测 ImageDiskCache.swift 就这样复活过）。
        entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': None})
        print('  del :', path)
        continue
    content = open(f, 'rb').read()
    blob = api('POST', '/git/blobs', {'content': base64.b64encode(content).decode(), 'encoding': 'base64'})
    entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
    print('  blob:', path)

tree = api('POST', '/git/trees', {'base_tree': base_tree, 'tree': entries})
commit = api('POST', '/git/commits', {'message': msg, 'tree': tree['sha'], 'parents': [parent]})
req = urllib.request.Request(API + '/git/refs/heads/main', method='PATCH')
req.add_header('Authorization', f'Bearer {TOKEN}')
req.add_header('Accept', 'application/vnd.github+json')
r = urllib.request.urlopen(req, data=json.dumps({'sha': commit['sha'], 'force': False}).encode(), timeout=60)
print('推送成功:', json.loads(r.read())['object']['sha'])
