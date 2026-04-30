"""Runtime configuration assembled from CLI flags + environment variables."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    bitbucket_workspace: str
    bitbucket_user: str
    bitbucket_app_password: str
    github_token: str
    github_org: str | None         # None means "create under authenticated user"
    work_dir: str
    dry_run: bool
    skip_existing: bool
    rename: dict[str, str]         # bitbucket_slug -> github_repo_name override


def _require_env(name: str) -> str:
    val = os.environ.get(name, "")
    if not val:
        raise SystemExit(f"environment variable {name} is required")
    return val


def load(
    *,
    workspace: str,
    github_org: str | None,
    work_dir: str,
    dry_run: bool,
    skip_existing: bool,
    rename: dict[str, str] | None = None,
) -> Config:
    return Config(
        bitbucket_workspace=workspace,
        bitbucket_user=_require_env("BITBUCKET_USERNAME"),
        bitbucket_app_password=_require_env("BITBUCKET_APP_PASSWORD"),
        github_token=_require_env("GITHUB_TOKEN"),
        github_org=github_org,
        work_dir=work_dir,
        dry_run=dry_run,
        skip_existing=skip_existing,
        rename=rename or {},
    )
