"""CLI entry point: `python -m b2g ...`."""
from __future__ import annotations

import argparse
import sys

from . import config, migrate


def _parse_rename(values: list[str] | None) -> dict[str, str]:
    out: dict[str, str] = {}
    for v in values or []:
        if "=" not in v:
            raise SystemExit(f"--rename expects SRC=DST, got: {v}")
        src, dst = v.split("=", 1)
        out[src.strip()] = dst.strip()
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="b2g",
        description=(
            "Migrate every repository from a Bitbucket workspace to GitHub, "
            "preserving privacy and Git LFS objects."
        ),
    )
    p.add_argument(
        "-w", "--workspace", required=True,
        help="Bitbucket workspace (team) slug",
    )
    p.add_argument(
        "--github-org", default=None,
        help="Create repos under this GitHub organization "
             "(default: authenticated user)",
    )
    p.add_argument(
        "--work-dir", default="/tmp/b2g",
        help="Local directory used for mirror clones (default: /tmp/b2g)",
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help="Plan only — list repos and what would happen, no writes",
    )
    p.add_argument(
        "--skip-existing", action="store_true",
        help="If a repo already exists on GitHub, leave it alone "
             "instead of pushing into it",
    )
    p.add_argument(
        "--rename", action="append", metavar="SRC=DST",
        help="Override destination repo name. May be passed multiple times.",
    )
    args = p.parse_args(argv)

    cfg = config.load(
        workspace=args.workspace,
        github_org=args.github_org,
        work_dir=args.work_dir,
        dry_run=args.dry_run,
        skip_existing=args.skip_existing,
        rename=_parse_rename(args.rename),
    )
    failures = migrate.run(cfg)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
