"""Conditional (If-None-Match) REST reads for the delivery script, with an on-disk cache.

A 304 answers from the cached body, so an unchanged resource costs no quota.
Pages are revalidated one by one: each page is its own resource with its own ETag.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .github_client import parse_include

PAGE_SIZE = 100
# Bounded like the GitHub client's cache: least recently written entries go first.
_MAX_CACHE_ENTRIES = 2000

RestRunner = Callable[[list[str], Path | None], Any]


class RestReadError(RuntimeError):
    """A REST read did not yield a usable body."""


@dataclass(frozen=True)
class _Entry:
    etag: str
    body: str


class ConditionalRestCache:
    def __init__(self, runner: RestRunner, cache_dir: Path) -> None:
        self.runner = runner
        self.cache_dir = cache_dir

    def get(self, endpoint: str, cwd: Path | None) -> Any:
        """One GET of ``endpoint``, revalidated when a body with an ETag is cached."""

        cached = self._read(endpoint)
        status, etag, body = self._send(endpoint, cwd, cached.etag if cached else None)
        if status == 304:
            # Only a validator we sent can earn a 304, so a cached body must exist.
            if cached is None:
                raise RestReadError(f"304 without a cached body for {endpoint}")
            return self._parse(endpoint, cached.body)
        doc = self._parse(endpoint, body)
        self._write(endpoint, etag, body)
        return doc

    def _parse(self, endpoint: str, body: str) -> Any:
        try:
            return json.loads(body)
        except ValueError as error:
            raise RestReadError(f"invalid JSON from {endpoint}") from error

    def get_pages(
        self, endpoint: str, cwd: Path | None, key: str | None = None
    ) -> list[Any]:
        """Every item of a paginated list; ``key`` names the list inside each page."""

        if f"per_page={PAGE_SIZE}" not in endpoint:
            raise ValueError(
                f"paginated read must set per_page={PAGE_SIZE}: {endpoint}"
            )
        separator = "&" if "?" in endpoint else "?"
        rows: list[Any] = []
        page_number = 1
        while True:
            page = self.get(f"{endpoint}{separator}page={page_number}", cwd)
            items = page.get(key, []) if key and isinstance(page, dict) else page
            if not isinstance(items, list):
                raise RestReadError(f"unexpected page shape from {endpoint}")
            rows.extend(items)
            # A short page is the last one; GitHub fills every earlier page.
            if len(items) < PAGE_SIZE:
                return rows
            page_number += 1

    def _send(
        self, endpoint: str, cwd: Path | None, etag: str | None
    ) -> tuple[int, str | None, str]:
        """(status, ETag, body) of one ``gh api --include`` GET."""

        argv = ["gh", "api", "--include"]
        if etag is not None:
            argv += ["-H", f"If-None-Match: {etag}"]
        argv.append(endpoint)
        done = self.runner(argv, cwd)
        response = parse_include(done.stdout)
        if response is None:
            # No status line: the output is the bare body, so there is no ETag to keep.
            if done.returncode != 0:
                raise RestReadError(f"read {endpoint} failed: {done.stderr.strip()}")
            return 200, None, done.stdout.strip()
        if response.status == 304:
            return 304, etag, ""
        if response.status >= 400 or done.returncode != 0:
            raise RestReadError(
                f"HTTP {response.status} for {endpoint}: {response.body.strip()[:200]}"
            )
        return response.status, response.headers.get("etag"), response.body.strip()

    def _path(self, endpoint: str) -> Path:
        digest = hashlib.sha256(endpoint.encode("utf-8")).hexdigest()
        return self.cache_dir / "rest" / f"{digest}.json"

    def _read(self, endpoint: str) -> _Entry | None:
        try:
            raw = json.loads(self._path(endpoint).read_text(encoding="utf-8"))
            return _Entry(etag=str(raw["etag"]), body=str(raw["body"]))
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def _write(self, endpoint: str, etag: str | None, body: str) -> None:
        """Store a tagged body; an untagged answer invalidates whatever was cached."""

        path = self._path(endpoint)
        try:
            if etag is None:
                path.unlink(missing_ok=True)
                return
            path.parent.mkdir(parents=True, exist_ok=True)
            # Write-then-rename: a concurrent reader sees the old or the new entry, never a torn one.
            descriptor, tmp_name = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"etag": etag, "body": body}))
            os.replace(tmp_name, path)
        except OSError:
            return
        self._prune(path.parent)

    def _prune(self, directory: Path) -> None:
        try:
            entries = list(directory.glob("*.json"))
            excess = len(entries) - _MAX_CACHE_ENTRIES
            if excess <= 0:
                return
            for stale in sorted(entries, key=lambda item: item.stat().st_mtime)[
                :excess
            ]:
                stale.unlink(missing_ok=True)
        except OSError:
            return
