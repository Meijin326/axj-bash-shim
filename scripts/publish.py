#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""device-camouflage 发布工具。

本机（Windows）到 github.com 的 git 端点长年不稳（直连超时、代理 502 轮流来），
所以这里完全绕开 `git push`，改用 GitHub Git Data API 造提交：
    blob -> tree -> commit -> 更新 ref
然后再轮询 Actions、把 deb 产物拉回来。

用法：
    python scripts/publish.py push            # 推当前 HEAD 的内容到远端 main
    python scripts/publish.py watch           # 等最新一次 Actions 跑完
    python scripts/publish.py pull            # 下载产物 zip 到 ../dist/
    python scripts/publish.py all             # push -> watch -> pull

token 取法：优先环境变量 GH_TOKEN，否则回落到本机已有的 git 凭据文件。
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

REPO = os.environ.get("GH_REPO", "Meijin326/device-camouflage")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.environ.get("DC_DIST", os.path.join(os.path.dirname(ROOT), "dist"))
BRANCH = os.environ.get("GH_BRANCH", "main")
CRED_FALLBACK = os.environ.get(
    "GH_CRED_FILE",
    r"C:/Users/Administrator/Desktop/小程序软件/bill-app-cli/.git/kaidan-credentials",
)

# 走裸 urllib 并清空代理：本机注入的 http_proxy 会伪造响应，不能信。
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _token():
    t = os.environ.get("GH_TOKEN")
    if t:
        return t.strip()
    if os.path.exists(CRED_FALLBACK):
        txt = open(CRED_FALLBACK, encoding="utf-8", errors="replace").read().strip()
        m = re.match(r"https?://[^:]+:([^@]+)@", txt)
        if m:
            return m.group(1)
    raise SystemExit("找不到 token：设 GH_TOKEN 环境变量，或确认凭据文件存在")


TOK = _token()


def log(*a):
    print(" ".join(str(x) for x in a), flush=True)


def api(path, method="GET", payload=None, raw=False):
    body = json.dumps(payload).encode() if payload is not None else None
    hdr = {
        "Authorization": "token " + TOK,
        "User-Agent": "device-camouflage-publish",
        "Accept": "application/vnd.github+json",
    }
    if body:
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request("https://api.github.com" + path,
                                 data=body, method=method, headers=hdr)
    try:
        with OPENER.open(req, timeout=60) as r:
            data = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        raise SystemExit("GitHub API %s %s -> HTTP %s\n%s" % (method, path, e.code, detail))
    return data if raw else json.loads(data.decode() or "{}")


def ensure_initialized():
    """全新的空仓库下 Git Data API 一律 409（Git Repository is empty.），
    必须先用 Contents API 打一个提交，把 git 存储初始化出来。"""
    try:
        api("/repos/%s/git/ref/heads/%s" % (REPO, BRANCH))
        return False
    except SystemExit as e:
        if "HTTP 404" not in str(e) and "HTTP 409" not in str(e):
            raise
    api("/repos/%s/contents/README.md" % REPO, "PUT",
        {"message": "chore: init repository [skip ci]",
         "content": base64.b64encode(b"# DeviceCamouflage\n").decode()})
    log("空仓库 -> 已用 Contents API 打初始提交")
    return True


def git(*args):
    return subprocess.check_output(["git", "-C", ROOT] + list(args))


# --------------------------------------------------------------------------- push

def push(message=None):
    if message is None:
        message = git("log", "-1", "--pretty=%B").decode().strip()

    ensure_initialized()

    entries = []
    for line in git("ls-tree", "-r", "HEAD").decode("utf-8").splitlines():
        meta, path = line.split("\t", 1)
        mode, _typ, sha = meta.split()
        content = git("cat-file", "blob", sha)          # 原始字节，不过滤 CRLF
        blob = api("/repos/%s/git/blobs" % REPO, "POST",
                   {"content": base64.b64encode(content).decode(), "encoding": "base64"})
        entries.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
        log("   blob %-40s %9d  %s" % (path, len(content), blob["sha"][:8]))

    tree = api("/repos/%s/git/trees" % REPO, "POST", {"tree": entries})

    parents = []
    try:
        ref = api("/repos/%s/git/ref/heads/%s" % (REPO, BRANCH))
        parents = [ref["object"]["sha"]]
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise

    commit = api("/repos/%s/git/commits" % REPO, "POST",
                 {"message": message, "tree": tree["sha"], "parents": parents})

    if parents:
        api("/repos/%s/git/refs/heads/%s" % (REPO, BRANCH), "PATCH", {"sha": commit["sha"]})
    else:
        api("/repos/%s/git/refs" % REPO, "POST",
            {"ref": "refs/heads/%s" % BRANCH, "sha": commit["sha"]})

    log("pushed -> %s@%s  (%d files)" % (REPO, commit["sha"][:8], len(entries)))
    return commit["sha"]


# -------------------------------------------------------------------------- watch

def latest_run():
    runs = api("/repos/%s/actions/runs?branch=%s&per_page=5" % (REPO, BRANCH))["workflow_runs"]
    return runs[0] if runs else None


def watch(timeout=1800):
    time.sleep(8)                       # 给 GitHub 一点时间把 run 建出来
    run = latest_run()
    if not run:
        log("没找到 workflow run"); return None
    log("run #%s  %s" % (run["run_number"], run["html_url"]))
    t0 = time.time()
    while time.time() - t0 < timeout:
        run = api("/repos/%s/actions/runs/%s" % (REPO, run["id"]))
        status, concl = run["status"], run.get("conclusion")
        log("   [%4ds] %s / %s" % (time.time() - t0, status, concl or "-"))
        if status == "completed":
            jobs = api("/repos/%s/actions/runs/%s/jobs" % (REPO, run["id"]))["jobs"]
            for j in jobs:
                log("   job %-28s %s" % (j["name"], j.get("conclusion")))
                if j.get("conclusion") not in ("success", "skipped", None):
                    for st in j.get("steps", []):
                        log("        step %-28s %s" % (st["name"], st.get("conclusion")))
            return run
        time.sleep(20)
    log("等超时了")
    return None


# --------------------------------------------------------------------------- pull

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def download_artifact(url):
    """artifact 下载会 302 到 Azure SAS URL。
    第二跳必须把 Authorization 摘掉，带着 token 过去会被 Azure 判 403
    （Server failed to authenticate ... including the signature）。"""
    req = urllib.request.Request(url, headers={"Authorization": "token " + TOK})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)
    try:
        with opener.open(req, timeout=120) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code not in (301, 302, 303, 307, 308):
            raise
        loc = e.headers.get("Location")
    if not loc:
        raise SystemExit("artifact 重定向没有 Location")
    with OPENER.open(urllib.request.Request(loc, headers={"User-Agent": "dc-publish"}),
                     timeout=180) as r:
        return r.read()


def pull():
    run = latest_run()
    if not run:
        log("没有 run 可拉"); return []
    arts = api("/repos/%s/actions/runs/%s/artifacts" % (REPO, run["id"]))["artifacts"]
    os.makedirs(DIST, exist_ok=True)
    out = []
    for a in arts:
        log("artifact %s (%s bytes)" % (a["name"], a["size_in_bytes"]))
        data = download_artifact(a["archive_download_url"])
        zpath = os.path.join(DIST, a["name"] + ".zip")
        open(zpath, "wb").write(data)
        with zipfile.ZipFile(zpath) as z:
            for n in z.namelist():
                target = os.path.join(DIST, os.path.basename(n))
                with z.open(n) as src, open(target, "wb") as dst:
                    dst.write(src.read())
                out.append(target)
                log("   -> %s (%d bytes)" % (target, os.path.getsize(target)))
        os.remove(zpath)
    return out


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    if cmd == "push":
        push()
    elif cmd == "watch":
        run = watch()
        sys.exit(0 if run and run.get("conclusion") == "success" else 1)
    elif cmd == "pull":
        pull()
    else:
        push()
        run = watch()
        if run and run.get("conclusion") == "success":
            pull()
        else:
            log("构建没成功，跳过下载")
            sys.exit(1)
