"""End-to-end orchestration: list, create, mirror-clone, mirror-push, LFS."""
from __future__ import annotations

import os

from . import bitbucket, git, github, log
from .config import Config


def _target_name(cfg: Config, slug: str) -> str:
    return cfg.rename.get(slug, slug)


def migrate_one(cfg: Config, owner: str, repo: bitbucket.BBRepo) -> None:
    target_name = _target_name(cfg, repo.slug)

    created = github.ensure_repo(
        cfg, owner, target_name, repo.description, repo.is_private
    )
    if not created and cfg.skip_existing:
        log.info("    skip-existing set; leaving destination untouched")
        return

    src_url = git.authed_url(
        repo.https_clone_url, cfg.bitbucket_user, cfg.bitbucket_secret
    )
    local_path = os.path.join(cfg.work_dir, f"{repo.slug}.git")
    dst_url = github.clone_url(owner, target_name)
    # GitHub accepts any non-empty username when using a PAT; the conventional
    # `x-access-token` makes the credential's role obvious in logs.
    dst_authed = git.authed_url(dst_url, "x-access-token", cfg.github_token)

    if cfg.dry_run:
        log.info(f"    [dry-run] would clone --mirror {repo.https_clone_url}")
        log.info(f"    [dry-run] would push  --mirror -> {dst_url}")
        return

    git.mirror_clone(src_url, local_path)
    git.fetch_all_lfs(local_path)
    git.mirror_push(local_path, dst_authed)
    git.push_all_lfs(local_path, dst_authed)


def run(cfg: Config) -> int:
    """Returns the number of repositories that failed to migrate."""
    git.ensure_dir(cfg.work_dir)
    log.info(f"listing repositories in workspace {cfg.bitbucket_workspace}")
    repos = bitbucket.list_repositories(cfg)
    log.info(f"found {len(repos)} repository(ies)")

    owner = github.owner_login(cfg)
    log.info(f"GitHub destination owner: {owner}")

    failures = 0
    total = len(repos)
    for idx, repo in enumerate(repos, start=1):
        privacy = "private" if repo.is_private else "public"
        log.info(f"==> ({idx}/{total}) {repo.slug} [{privacy}]")
        try:
            migrate_one(cfg, owner, repo)
            log.info(f"    done: {repo.slug}")
        except Exception as e:  # noqa: BLE001 — we want to keep going
            failures += 1
            log.error(f"    FAILED {repo.slug}: {e}")
    log.info(f"completed; {total - failures}/{total} succeeded")
    return failures
