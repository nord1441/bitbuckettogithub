"""Tiny logger so we don't drag in the stdlib `logging` module's defaults."""
from __future__ import annotations

import sys


def _emit(tag: str, msg: str, stream=sys.stdout) -> None:
    print(f"[{tag}] {msg}", file=stream, flush=True)


def info(msg: str) -> None:
    _emit("info", msg)


def step(msg: str) -> None:
    _emit("step", msg)


def warn(msg: str) -> None:
    _emit("warn", msg, stream=sys.stderr)


def error(msg: str) -> None:
    _emit("error", msg, stream=sys.stderr)
