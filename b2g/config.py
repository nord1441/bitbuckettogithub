"""Runtime configuration assembled from CLI flags + environment variables."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    bitbucket_workspace: str
    # For API tokens this is the Atlassian account email; for legacy
    # App Passwords it is the Bitbucket username.
    bitbucket_user: str
    # API token (preferred) or App Password (legacy).
    bitbucket_secret: str
    github_token: str
    github_org: str | None         # None means "create under authenticated user"
    work_dir: str
    dry_run: bool
    skip_existing: bool
    rename: dict[str, str]         # bitbucket_slug -> github_repo_name override


def _first_env(*names: str) -> tuple[str, str]:
    """Return (name, value) of the first env var in `names` that is set
    and non-empty. Raises SystemExit if none are."""
    for n in names:
        v = os.environ.get(n, "")
        if v:
            return n, v
    raise SystemExit(
        "missing required environment variable; set one of: "
        + ", ".join(names)
    )


def load(
    *,
    workspace: str,
    github_org: str | None,
    work_dir: str,
    dry_run: bool,
    skip_existing: bool,
    rename: dict[str, str] | None = None,
) -> Config:
    # Atlassian deprecated Bitbucket Cloud App Passwords in 2025; the
    # replacement is API tokens authenticated with the account email.
    # Accept both naming conventions so existing setups keep working.
    _, user = _first_env(
        "BITBUCKET_EMAIL",      # preferred when using API tokens
        "BITBUCKET_USERNAME",   # legacy app-password setups
    )
    _, secret = _first_env(
        "BITBUCKET_API_TOKEN",  # preferred
        "BITBUCKET_APP_PASSWORD",
    )
    _, gh_tok = _first_env("GITHUB_TOKEN")

    return Config(
        bitbucket_workspace=workspace,
        bitbucket_user=user,
        bitbucket_secret=secret,
        github_token=gh_tok,
        github_org=github_org,
        work_dir=work_dir,
        dry_run=dry_run,
        skip_existing=skip_existing,
        rename=rename or {},
    )
