"""The ops-edit entrypoint must initialize Sentry so handled failures are reported."""

from __future__ import annotations

import argparse
import sys

import pytest

import kg.ops_edit_parser as parser_mod


def _fake_parser(calls: list[str]) -> argparse.ArgumentParser:
    def _run(args: argparse.Namespace) -> int:
        calls.append("func")
        return 0

    parser = argparse.ArgumentParser()
    parser.set_defaults(func=_run, cmd="noop")
    return parser


def test_main_initializes_sentry_with_ops_edit_job_before_running_command(monkeypatch):
    calls: list[str] = []
    init_calls: list[dict] = []

    def _recording_init(**kwargs):
        calls.append("init")
        init_calls.append(kwargs)
        return False

    monkeypatch.setattr(parser_mod, "init_sentry", _recording_init)
    monkeypatch.setattr(parser_mod, "build_parser", lambda: _fake_parser(calls))
    monkeypatch.setattr(sys, "argv", ["ops_edit"])

    with pytest.raises(SystemExit) as exc:
        parser_mod.main()

    assert exc.value.code == 0
    assert init_calls == [{"job": "ops_edit"}]
    assert calls == ["init", "func"]
