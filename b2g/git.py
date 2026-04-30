"""Wrappers around the local `git` and `git-lfs` CLIs."""
from __future__ import annotations

import os
import shutil
import subprocess
from urllib.parse import quote

from . import log


def authed_url(url: str, user: str, token: str) -> str:
    """Embed `user:token@` in an https URL so credentials never touch disk.

    Both `user` and `token` are URL-encoded so e.g. `@` in tokens stays safe.
    """
    if not url.startswith("https://"):
        return url
    rest = url[len("https://"):]
    return f"https://{quote(user, safe='')}:{quote(token, safe='')}@{rest}"


def have_git_lfs() -> bool:
    return shutil.which("git-lfs") is not None


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def _run(args: list[str], cwd: str | None = None, check: bool = True) -> int:
    # Don't print authed URLs verbatim; mask the credentials portion.
    log.step("git " + " ".join(_mask(a) for a in args))
    proc = subprocess.run(["git", *args], cwd=cwd, check=False)
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed (exit {proc.returncode})"
        )
    return proc.returncode


def _mask(arg: str) -> str:
    """Hide `user:token@` segments from log output."""
    if "://" not in arg:
        return arg
    scheme, _, rest = arg.partition("://")
    if "@" not in rest:
        return arg
    cred, _, host = rest.partition("@")
    if ":" not in cred:
        return arg
    user, _, _ = cred.partition(":")
    return f"{scheme}://{user}:***@{host}"


def mirror_clone(src_authed_url: str, dst_dir: str) -> None:
    """`git clone --mirror`. Idempotent: removes any pre-existing dst."""
    if os.path.isdir(dst_dir):
        shutil.rmtree(dst_dir)
    _run(["clone", "--mirror", src_authed_url, dst_dir])


def fetch_all_lfs(repo_dir: str) -> None:
    if not have_git_lfs():
        log.warn("  git-lfs not installed; LFS objects will not be fetched")
        return
    try:
        _run(["lfs", "fetch", "--all"], cwd=repo_dir)
    except RuntimeError as e:
        # Repo may not actually use LFS; treat as a soft failure.
        log.warn(f"  git lfs fetch --all skipped: {e}")


def mirror_push(repo_dir: str, dst_authed_url: str) -> None:
    _run(["push", "--mirror", dst_authed_url], cwd=repo_dir)


def push_all_lfs(repo_dir: str, dst_authed_url: str) -> None:
    if not have_git_lfs():
        return
    try:
        _run(["lfs", "push", "--all", dst_authed_url], cwd=repo_dir)
    except RuntimeError as e:
        log.warn(f"  git lfs push --all skipped: {e}")
