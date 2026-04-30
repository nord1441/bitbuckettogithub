"""Minimal GitHub REST client for repository creation / lookup."""
from __future__ import annotations

import json
import urllib.error
import urllib.request

from . import log
from .config import Config

API_BASE = "https://api.github.com"


def _headers(cfg: Config) -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Authorization": f"Bearer {cfg.github_token}",
        "User-Agent": "b2g-py/0.1",
    }


def _request(
    method: str,
    url: str,
    headers: dict[str, str],
    body: dict | None = None,
) -> tuple[int, dict | None]:
    data: bytes | None = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers = {**headers, "Content-Type": "application/json"}
    req = urllib.request.Request(url, headers=headers, method=method, data=data)
    try:
        with urllib.request.urlopen(req) as resp:
            payload = resp.read().decode("utf-8")
            return resp.status, (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as e:
        # 404 is a normal "doesn't exist" answer for our use case; bubble up.
        text = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(text) if text else None
        except json.JSONDecodeError:
            return e.code, {"raw": text}


def owner_login(cfg: Config) -> str:
    """The login under which new repositories will be created."""
    if cfg.github_org:
        return cfg.github_org
    code, body = _request("GET", f"{API_BASE}/user", _headers(cfg))
    if code != 200 or not body or "login" not in body:
        raise SystemExit(f"GitHub /user failed: HTTP {code} {body}")
    return body["login"]


def repo_exists(cfg: Config, owner: str, name: str) -> bool:
    code, _ = _request(
        "GET", f"{API_BASE}/repos/{owner}/{name}", _headers(cfg)
    )
    return code == 200


def create_repo(cfg: Config, name: str, description: str, private: bool) -> None:
    payload = {
        "name": name,
        "description": description,
        "private": private,
        "has_issues": True,
        "has_wiki": False,
        "auto_init": False,
    }
    if cfg.github_org:
        url = f"{API_BASE}/orgs/{cfg.github_org}/repos"
    else:
        url = f"{API_BASE}/user/repos"
    code, body = _request("POST", url, _headers(cfg), body=payload)
    if code not in (201, 202):
        raise SystemExit(
            f"GitHub repo creation failed for {name}: HTTP {code} {body}"
        )


def ensure_repo(
    cfg: Config, owner: str, name: str, description: str, private: bool
) -> bool:
    """Create the repo if missing. Returns True iff a new repo was created."""
    if repo_exists(cfg, owner, name):
        log.info(f"github repo already exists: {owner}/{name}")
        return False
    log.step(
        f"creating github repo {owner}/{name} "
        f"({'private' if private else 'public'})"
    )
    if cfg.dry_run:
        return True
    create_repo(cfg, name, description, private)
    return True


def clone_url(owner: str, name: str) -> str:
    return f"https://github.com/{owner}/{name}.git"
