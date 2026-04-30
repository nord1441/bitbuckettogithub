"""Bitbucket Cloud REST client (just enough to list repositories)."""
from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Iterator

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


def _open(
    url: str, headers: dict[str, str], *, raise_on_error: bool = True
) -> tuple[int, dict | None, str]:
    """Returns (status, json_body_or_None, raw_body)."""
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            payload = resp.read().decode("utf-8")
            return resp.status, (json.loads(payload) if payload else None), payload
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", errors="replace")
        if raise_on_error:
            _raise_api_error(e.code, url, text, e.headers)
        try:
            return e.code, json.loads(text) if text else None, text
        except json.JSONDecodeError:
            return e.code, None, text


def _raise_api_error(
    code: int, url: str, body: str, headers: Any | None = None
) -> None:
    snippet = body[:500] or "(empty body)"
    extra = ""
    if headers is not None:
        wa = headers.get("WWW-Authenticate")
        if wa:
            extra = f"\n  WWW-Authenticate: {wa}"
    raise SystemExit(
        f"Bitbucket API error {code} for {url}:\n  {snippet}{extra}"
    )


def _check_credentials(headers: dict[str, str]) -> dict | None:
    """Hit /user. Returns the parsed user object on success, raises with a
    clear message on auth failure."""
    code, body, raw = _open(
        f"{API_BASE}/user", headers, raise_on_error=False
    )
    if code == 200 and body is not None:
        return body
    if code in (401, 403):
        raise SystemExit(
            "Bitbucket authentication failed (HTTP "
            f"{code} on /2.0/user).\n"
            "  Recommended setup (API token, current Atlassian standard):\n"
            "    BITBUCKET_EMAIL     = your Atlassian account email\n"
            "    BITBUCKET_API_TOKEN = token from https://id.atlassian.com/manage-profile/security/api-tokens\n"
            "  The token must include the Bitbucket scopes:\n"
            "    read:account, read:repository:bitbucket\n"
            "  Legacy setup (App Password, being phased out):\n"
            "    BITBUCKET_USERNAME      = your Bitbucket username (NOT email)\n"
            "    BITBUCKET_APP_PASSWORD  = app password with\n"
            "      'Account: Read' and 'Repositories: Read' scopes\n"
            f"  Response body: {raw[:400] or '(empty)'}"
        )
    _raise_api_error(code, f"{API_BASE}/user", raw)
    return None  # unreachable


def _list_workspace_slugs(headers: dict[str, str]) -> list[str]:
    code, body, _raw = _open(
        f"{API_BASE}/workspaces?pagelen=100", headers, raise_on_error=False
    )
    if code != 200 or not body:
        return []
    return [v.get("slug") for v in body.get("values", []) if v.get("slug")]


def list_repositories(cfg: Config) -> list[BBRepo]:
    headers = {
        "Accept": "application/json",
        "Authorization": _basic_auth_header(
            cfg.bitbucket_user, cfg.bitbucket_secret
        ),
        "User-Agent": "b2g-py/0.1",
    }

    # Pre-flight 1: validate credentials. This turns the most common failure
    # mode (bad PAT/app-password) into an actionable message before we touch
    # any workspace-specific endpoint.
    user = _check_credentials(headers)
    if user is not None:
        log.info(
            f"bitbucket auth ok as "
            f"{user.get('username') or user.get('display_name') or '?'}"
        )

    url: str | None = (
        f"{API_BASE}/repositories/{cfg.bitbucket_workspace}"
        "?pagelen=100&role=member"
    )
    out: list[BBRepo] = []
    first = True
    while url:
        if first:
            first = False
            code, page, raw = _open(url, headers, raise_on_error=False)
            if code in (401, 403, 404):
                slugs = _list_workspace_slugs(headers)
                hint = (
                    "\n  Available workspaces for this credential: "
                    + (", ".join(slugs) if slugs else "(none found)")
                )
                raise SystemExit(
                    f"Bitbucket workspace '{cfg.bitbucket_workspace}' is not "
                    f"accessible (HTTP {code}).{hint}\n"
                    "  Pass one of the slugs above with --workspace."
                )
            if code >= 400 or page is None:
                _raise_api_error(code, url, raw)
        else:
            _code, page, _raw = _open(url, headers)
        assert page is not None
        for repo_obj in page.get("values", []):
            r = _parse_repo(repo_obj)
            if r is not None:
                out.append(r)
        url = page.get("next")
    return out


def iter_repositories(cfg: Config) -> Iterator[BBRepo]:
    """Streaming variant; useful for very large workspaces."""
    yield from list_repositories(cfg)
