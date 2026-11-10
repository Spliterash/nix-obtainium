"""nix-obtainium connector for GitHub releases.

URL: file+https://nix-obtainium.invalid/github/<owner>/<repo>?asset=<glob>[&tag=<glob>][&prerelease=1]
Picks the newest release whose tag matches `tag` and that has an asset matching `asset`.
"""
import fnmatch
import json
import os
import re
import sys
import urllib.request

req = json.load(sys.stdin)
if len(req["path"]) != 2 or "asset" not in req["query"]:
    sys.exit("expected github/<owner>/<repo>?asset=<glob>")
owner, repo = req["path"]
q = req["query"]
asset_glob = q["asset"]
tag_glob = q.get("tag", "*")
prerelease = q.get("prerelease") in ("1", "true")

headers = {"Accept": "application/vnd.github+json", "User-Agent": "nix-obtainium"}
token = req.get("accessTokens", {}).get("github.com") or os.environ.get("GITHUB_TOKEN")
if token:
    headers["Authorization"] = f"Bearer {token}"


def pages():
    url = f"https://api.github.com/repos/{owner}/{repo}/releases?per_page=100"
    while url:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as r:
            yield json.load(r)
            nxt = re.search(r'<([^>]+)>;\s*rel="next"', r.headers.get("Link", ""))
            url = nxt and nxt.group(1)


for page in pages():
    for rel in page:
        if rel["draft"] or (rel["prerelease"] and not prerelease):
            continue
        if not fnmatch.fnmatchcase(rel["tag_name"], tag_glob):
            continue
        for a in rel["assets"]:
            if fnmatch.fnmatchcase(a["name"], asset_glob):
                version = re.sub(r"^v(?=\d)", "", rel["tag_name"])
                json.dump({"version": version, "url": a["browser_download_url"]}, sys.stdout)
                sys.exit(0)

sys.exit(f"no release of {owner}/{repo} with asset matching '{asset_glob}' (tag '{tag_glob}')")
