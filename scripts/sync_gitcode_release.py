#!/usr/bin/env python3
"""Sync a GitHub Release (tag, notes, and .deb assets) to GitCode (AtomGit) v5 API."""

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

GITCODE_API_BASE = os.environ.get("GITCODE_API_BASE", "https://api.gitcode.com/api/v5")
GITCODE_OWNER = os.environ.get("GITCODE_OWNER", "m0_60692907")
GITCODE_REPO = os.environ.get("GITCODE_REPO", "AgentOS")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "LJ-ZXY/AgentOS")


def http_json(url, method="GET", payload=None, headers=None, timeout=30):
    req_headers = {"Accept": "application/json", "User-Agent": "AgentOS-Sync/1.0"}
    if headers:
        req_headers.update(headers)
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        req_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return exc.code, {"error": body}


def download_file(url, dest_path, headers=None, timeout=180):
    req_headers = {"User-Agent": "AgentOS-Sync/1.0"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, headers=req_headers, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp, open(dest_path, "wb") as out:
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            out.write(chunk)


def put_binary_file(url, file_path, headers, timeout=600):
    """Stream-upload a release attachment via curl HTTP/1.1 PUT without Expect: 100-continue stalls."""
    cmd = [
        "curl",
        "-sS",
        "--fail-with-body",
        "--http1.1",
        "--retry", "3",
        "--retry-delay", "2",
        "-m", str(timeout),
        "-X", "PUT",
        "-H", "Expect:",
        "-w", "\nHTTP_STATUS:%{http_code}",
    ]
    for k, v in (headers or {}).items():
        cmd.extend(["-H", f"{k}: {v}"])
    cmd.extend(["-T", str(file_path), url])

    res = subprocess.run(cmd, capture_output=True, text=True)
    stdout = res.stdout or ""
    status = 0
    body = stdout
    if "HTTP_STATUS:" in stdout:
        body_part, status_part = stdout.rsplit("HTTP_STATUS:", 1)
        body = body_part.strip()
        try:
            status = int(status_part.strip())
        except ValueError:
            status = 0
    if res.returncode != 0 and status == 0:
        raise RuntimeError(f"curl PUT failed (rc={res.returncode}): {res.stderr.strip()} {body}")
    return status, body


def push_git_refs_to_gitcode(tag_name, token):
    owner_q = urllib.parse.quote(GITCODE_OWNER, safe="")
    remote_url = f"https://{owner_q}:{urllib.parse.quote(token, safe='')}@gitcode.com/{GITCODE_OWNER}/{GITCODE_REPO}.git"
    subprocess.run(["git", "fetch", "--tags", "--force"], check=False)
    for refspec in [
        "HEAD:refs/heads/main",
        f"refs/tags/{tag_name}:refs/tags/{tag_name}",
    ]:
        res = subprocess.run(
            ["git", "push", "--force", remote_url, refspec],
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            # Redact token if git echoes remote URL on error
            err_msg = (res.stderr or "").replace(urllib.parse.quote(token, safe=""), "***")
            print(f"Warning: git push {refspec} returned {res.returncode}: {err_msg}", file=sys.stderr)


def fetch_github_release(tag_name, gh_token):
    gh_headers = {"Accept": "application/vnd.github+json"}
    if gh_token:
        gh_headers["Authorization"] = f"Bearer {gh_token}"
    if tag_name:
        url = f"https://api.github.com/repos/{GITHUB_REPO}/releases/tags/{urllib.parse.quote(tag_name)}"
    else:
        url = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
    status, data = http_json(url, headers=gh_headers)
    if status != 200:
        raise RuntimeError(f"Failed to fetch GitHub release ({url}): HTTP {status} {data}")
    return data


def sync_release(gh_release, gc_token):
    tag_name = gh_release["tag_name"]
    rel_name = gh_release.get("name") or tag_name
    rel_body = gh_release.get("body") or f"Mirrored from GitHub release {tag_name}"
    release_status = "pre" if gh_release.get("prerelease") else "latest"

    owner_enc = urllib.parse.quote(GITCODE_OWNER, safe="")
    repo_enc = urllib.parse.quote(GITCODE_REPO, safe="")
    tag_enc = urllib.parse.quote(tag_name, safe="")
    tok_q = urllib.parse.urlencode({"access_token": gc_token})

    # Push branch & tag so GitCode release can bind cleanly
    push_git_refs_to_gitcode(tag_name, gc_token)

    tag_url = f"{GITCODE_API_BASE}/repos/{owner_enc}/{repo_enc}/releases/tags/{tag_enc}?{tok_q}"
    status, existing = http_json(tag_url)

    payload = {
        "tag_name": tag_name,
        "name": rel_name,
        "body": rel_body,
        "release_status": release_status,
    }

    if status == 200 and existing.get("tag_name"):
        patch_url = f"{GITCODE_API_BASE}/repos/{owner_enc}/{repo_enc}/releases/{tag_enc}?{tok_q}"
        p_status, res = http_json(patch_url, method="PATCH", payload={
            "name": rel_name,
            "body": rel_body,
            "release_status": release_status,
        })
        if p_status not in (200, 201):
            raise RuntimeError(f"Failed to update GitCode release: HTTP {p_status} {res}")
        print(f"Updated existing GitCode release {tag_name}")
    else:
        payload["target_commitish"] = "main"
        create_url = f"{GITCODE_API_BASE}/repos/{owner_enc}/{repo_enc}/releases?{tok_q}"
        c_status, res = http_json(create_url, method="POST", payload=payload)
        if c_status not in (200, 201):
            raise RuntimeError(f"Failed to create GitCode release: HTTP {c_status} {res}")
        print(f"Created GitCode release {tag_name}")
        existing = res

    # Re-fetch release to obtain existing attachment IDs
    _, existing = http_json(tag_url)
    existing_assets = {
        a.get("name"): a.get("id")
        for a in (existing.get("assets") or [])
        if a.get("name") and a.get("id")
    }

    gh_assets = [a for a in (gh_release.get("assets") or []) if (a.get("name") or "").endswith(".deb")]
    if not gh_assets:
        print("No .deb assets found in GitHub release; metadata sync complete.")
        return

    gh_token = os.environ.get("GITHUB_TOKEN", "")
    dl_headers = {}
    if gh_token:
        dl_headers["Authorization"] = f"Bearer {gh_token}"

    with tempfile.TemporaryDirectory() as tmpdir:
        for asset in gh_assets:
            fname = asset["name"]
            dl_url = asset["browser_download_url"]
            local_file = Path(tmpdir) / fname
            print(f"Downloading {fname} from GitHub...")
            download_file(dl_url, local_file, headers=dl_headers)

            # Delete old attachment with same name if present
            old_id = existing_assets.get(fname)
            if old_id:
                del_url = f"{GITCODE_API_BASE}/repos/{owner_enc}/{repo_enc}/releases/{tag_enc}/attach_files/{old_id}?{tok_q}"
                d_status, d_res = http_json(del_url, method="DELETE")
                print(f"Deleted old attachment {fname} (id={old_id}): HTTP {d_status}")

            up_q = urllib.parse.urlencode({"access_token": gc_token, "file_name": fname})
            up_info_url = f"{GITCODE_API_BASE}/repos/{owner_enc}/{repo_enc}/releases/{tag_enc}/upload_url?{up_q}"
            u_status, u_res = http_json(up_info_url, method="GET")
            if u_status != 200 or not u_res.get("url"):
                raise RuntimeError(f"Failed to get upload_url for {fname}: HTTP {u_status} {u_res}")

            put_status, put_body = put_binary_file(u_res["url"], str(local_file), u_res.get("headers") or {})
            if put_status not in (200, 201, 204):
                raise RuntimeError(f"PUT upload failed for {fname}: HTTP {put_status} {put_body}")
            print(f"Uploaded {fname} ({os.path.getsize(local_file)} bytes) to GitCode release {tag_name}")


def main():
    gc_token = os.environ.get("GITCODE_TOKEN", "").strip()
    if not gc_token:
        print("ERROR: GITCODE_TOKEN secret is not configured. Skipping GitCode sync.", file=sys.stderr)
        sys.exit(1)

    gh_token = os.environ.get("GITHUB_TOKEN", "").strip()
    tag_name = os.environ.get("INPUT_TAG_NAME", "").strip()

    event_path = os.environ.get("GITHUB_EVENT_PATH", "").strip()
    gh_release = None
    if not tag_name and event_path and os.path.exists(event_path):
        with open(event_path, "r", encoding="utf-8") as fp:
            evt = json.load(fp)
        if isinstance(evt.get("release"), dict):
            gh_release = evt["release"]
            tag_name = gh_release.get("tag_name") or ""

    if not gh_release or not gh_release.get("assets"):
        gh_release = fetch_github_release(tag_name, gh_token)

    sync_release(gh_release, gc_token)


if __name__ == "__main__":
    main()
