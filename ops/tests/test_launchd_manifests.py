"""Every ops/launchd/*.plist is the versioned source of a deployed job (#2071).

com.butler.kg-disk-guard.plist was named by no other file, was reported as a
dead leftover, and is in fact loaded on felix (~/Library/LaunchAgents,
StartInterval 300, last exit 0) — deleting it would have dropped the only
copy of that job's definition. An undocumented manifest is indistinguishable
from a dead one, so each must be named by at least one other tracked file that
says where it is installed, and carry a Label matching its filename (the name
`launchctl print gui/<uid>/<label>` and the docs use).

The Label is read with a regex, not plistlib: launchd's CFPropertyList parser
accepts the `--` inside the XML comments of com.kg.reconcile / com.kg.uisweep
(`plutil -lint` OK), strict expat does not.

    uv run --no-project --python 3.13 --with pytest pytest -q ops/tests/test_launchd_manifests.py
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

_ROOT = Path(__file__).resolve().parents[2]
_MANIFESTS = sorted((_ROOT / "ops" / "launchd").glob("*.plist"))
_LABEL_RE = re.compile(r"<key>Label</key>\s*<string>([^<]+)</string>")


def test_manifest_directory_is_found():
    assert _MANIFESTS, "positive control: no manifests under ops/launchd/"


@pytest.mark.parametrize("manifest", _MANIFESTS, ids=lambda p: p.name)
def test_manifest_label_matches_filename(manifest):
    labels = _LABEL_RE.findall(manifest.read_text(encoding="utf-8"))
    assert labels == [manifest.stem]


@pytest.mark.parametrize("manifest", _MANIFESTS, ids=lambda p: p.name)
def test_manifest_is_documented_elsewhere(manifest):
    rel = manifest.relative_to(_ROOT).as_posix()
    this_test = Path(__file__).resolve().relative_to(_ROOT).as_posix()  # names it above
    hits = subprocess.run(
        ["git", "-C", str(_ROOT), "grep", "-l", "--fixed-strings", manifest.name]
        + ["--", ".", f":(exclude){rel}", f":(exclude){this_test}"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert hits.returncode in (0, 1), hits.stderr
    assert hits.stdout.split(), (
        f"{rel} is named by no other tracked file — document where it is installed "
        "(docs/reference/host_topology.md) or delete it"
    )


# ── com.kg.log-retention: retired (#2091) ──
#
# Log retention is triggered only by the backend process's in-process scheduler
# (backend/src/kg/log_retention_scheduler.py). A launchd job alongside it would
# prune the same DBs twice, so the manifest is not kept.


def test_log_retention_has_no_launchd_manifest():
    assert not (_ROOT / "ops" / "launchd" / "com.kg.log-retention.plist").exists()
