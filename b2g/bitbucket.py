"""Bitbucket Cloud REST client (just enough to list repositories)."""
from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Iterator

from . import log
from .config import Config

API_BASE = "https://api.bitbucket.org/2.0"


@dataclass(frozen=True)
class BBRepo:
    slug: str
    name: str
    description: str
    is_private: bool
    https_clone_url: str  # without embedded credentials


def _basic_auth_header(user: str, password: str) -> str:
    raw = f"{user}:{password}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def _strip_userinfo(url: str) -> str:
    """Bitbucket's clone URLs embed `<user>@`; strip it."""
    if not url.startswith("https://"):
        return url
    body = url[len("https://"):]
    at = body.find("@")
    if at == -1:
        return url
    return "https://" + body[at + 1:]


def _https_clone_from_links(links: dict) -> str | None:
    for entry in links.get("clone", []) or []:
        if entry.get("name") == "https" and entry.get("href"):
            return _strip_userinfo(entry["href"])
    return None


def _parse_repo(obj: dict) -> BBRepo | None:
    slug = obj.get("slug")
    if not slug:
        return None
    href = _https_clone_from_links(obj.get("links") or {})
    if not href:
        log.warn(f"skipping {slug}: no https clone URL in API response")
        return None
    return BBRepo(
        slug=slug,
        name=obj.get("name") or slug,
        description=obj.get("description") or "",
        # Default to private if Bitbucket omits the field. Safer than the
        # alternative when we're about to mirror the contents to GitHub.
        is_private=bool(obj.get("is_private", True)),
        https_clone_url=href,
    )


def _open(url: str, headers: dict[str, str]) -> dict:
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            payload = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:500]
        raise SystemExit(
            f"Bitbucket API error {e.code} for {url}: {body}"
        ) from None
    return json.loads(payload)


def list_repositories(cfg: Config) -> list[BBRepo]:
    headers = {
        "Accept": "application/json",
        "Authorization": _basic_auth_header(
            cfg.bitbucket_user, cfg.bitbucket_app_password
        ),
        "User-Agent": "b2g-py/0.1",
    }
    url: str | None = (
        f"{API_BASE}/repositories/{cfg.bitbucket_workspace}"
        "?pagelen=100&role=member"
    )
    out: list[BBRepo] = []
    while url:
        page = _open(url, headers)
        for raw in page.get("values", []):
            r = _parse_repo(raw)
            if r is not None:
                out.append(r)
        url = page.get("next")
    return out


def iter_repositories(cfg: Config) -> Iterator[BBRepo]:
    """Streaming variant; useful for very large workspaces."""
    yield from list_repositories(cfg)
