from __future__ import annotations

import fcntl
import json
import os
from datetime import UTC, datetime

import pytest

import kg.user_store as user_store_mod
from kg.user_store import (
    collect_account_ids_for_deletion,
    load_users_from,
    normalize_users_payload,
    parse_datetime,
)


def _default_subscription():
    return {
        "is_active": False,
        "status": "inactive",
        "plan_name": None,
        "trial_days": 7,
        "will_renew": False,
    }


# ===========================================================================
# parse_datetime
# ===========================================================================


class TestParseDatetime:
    def test_iso_with_z_suffix(self):
        result = parse_datetime("2024-01-15T12:00:00Z")
        assert isinstance(result, datetime)
        assert result.tzinfo == UTC
        assert result.year == 2024
        assert result.month == 1
        assert result.day == 15

    def test_iso_with_offset(self):
        result = parse_datetime("2024-06-01T08:30:00+05:30")
        assert isinstance(result, datetime)
        assert result.tzinfo == UTC

    def test_unix_timestamp_int(self):
        result = parse_datetime(1700000000)
        assert isinstance(result, datetime)
        assert result.tzinfo == UTC
        assert result == datetime.fromtimestamp(1700000000, tz=UTC)

    def test_unix_timestamp_float(self):
        result = parse_datetime(1700000000.5)
        assert isinstance(result, datetime)
        assert result.tzinfo == UTC

    def test_invalid_string_returns_none(self):
        assert parse_datetime("not-a-date") is None

    def test_none_returns_none(self):
        assert parse_datetime(None) is None

    def test_datetime_with_utc_tzinfo(self):
        dt = datetime(2024, 1, 1, tzinfo=UTC)
        result = parse_datetime(dt)
        assert result == dt

    def test_naive_datetime_gets_utc(self):
        dt = datetime(2024, 1, 1)
        result = parse_datetime(dt)
        assert result.tzinfo == UTC

    @pytest.mark.parametrize(
        "raw",
        ["9999-12-31T23:59:59-05:00", "inf", "1e30", "1e18", 1e30, float("inf"), 10**30],
    )
    def test_out_of_range_returns_none(self, raw):
        assert parse_datetime(raw) is None


# ===========================================================================
# normalize_users_payload
# ===========================================================================


class TestLoadUsersFrom:
    def test_non_object_json_payload_raises_bounded_decode_error(self, tmp_path):
        users_file = tmp_path / "users.json"
        users_file.write_text("[]")

        with pytest.raises(json.JSONDecodeError, match="users.json payload must be a JSON object"):
            load_users_from(
                users_file,
                lambda users: normalize_users_payload(users, _default_subscription),
            )


class TestNormalizeUsersPayload:
    def _normalize(self, users):
        return normalize_users_payload(users, _default_subscription)

    def test_subscription_defaults_filled(self):
        users = {
            "u1": {"config": {}, "subscription": {"is_active": True, "status": "active"}},
        }
        result, changed = self._normalize(users)
        sub = result["u1"]["subscription"]
        assert "trial_days" in sub
        assert "will_renew" in sub

    def test_empty_integrations_cleaned_up(self):
        users = {
            "u1": {"config": {"integrations": {}}},
        }
        result, _ = self._normalize(users)
        assert "integrations" not in result["u1"].get("config", {})

    def test_already_normal_payload_returns_changed_false(self):
        users = {
            "u1": {
                "config": {},
            }
        }
        result, changed = self._normalize(users)
        assert not changed

    def test_retired_dictionary_review_setting_is_removed(self):
        users = {
            "u1": {
                "config": {
                    "review_mode": {
                        "mode": "relaxed",
                        "include_dictionary_cards": True,
                        "includeDictionaryCards": False,
                    }
                }
            }
        }

        result, changed = self._normalize(users)

        assert changed is True
        assert result["u1"]["config"]["review_mode"] == {"mode": "relaxed"}

    def test_underscore_prefixed_keys_pass_through(self):
        users = {
            "_revoked_before": {"u1": "2024-01-01"},
            "u1": {"config": {}},
        }
        result, _ = self._normalize(users)
        assert result["_revoked_before"] == {"u1": "2024-01-01"}


# ===========================================================================
# collect_account_ids_for_deletion
# ===========================================================================


class TestCollectAccountIdsForDeletion:
    def test_no_linked_accounts_returns_only_self(self):
        users = {"u1": {"config": {}}}
        canonical, ids = collect_account_ids_for_deletion(users, "u1")
        assert canonical == "u1"
        assert ids == ["u1"]

    def test_linked_to_points_to_canonical(self):
        users = {
            "canonical": {"linked_ids": ["linked1"], "config": {}},
            "linked1": {"_linked_to": "canonical"},
        }
        canonical, ids = collect_account_ids_for_deletion(users, "linked1")
        assert canonical == "canonical"
        assert "canonical" in ids
        assert "linked1" in ids

    def test_canonical_has_linked_ids_array(self):
        users = {
            "canonical": {"linked_ids": ["linked1", "linked2"], "config": {}},
            "linked1": {"_linked_to": "canonical"},
            "linked2": {"_linked_to": "canonical"},
        }
        canonical, ids = collect_account_ids_for_deletion(users, "canonical")
        assert canonical == "canonical"
        assert set(ids) == {"canonical", "linked1", "linked2"}

    def test_linked_to_nonexistent_canonical_safe(self):
        users = {
            "u1": {"_linked_to": "ghost_canonical"},
        }
        canonical, ids = collect_account_ids_for_deletion(users, "u1")
        assert canonical == "ghost_canonical"
        assert "u1" in ids
        assert "ghost_canonical" in ids


# ===========================================================================
# save_users_to durability (#3822)
# ===========================================================================


def test_save_users_to_fsyncs_tmp_before_replace_then_fsyncs_parent_dir(tmp_path, monkeypatch):
    events: list[tuple[str, object]] = []
    real_fsync = os.fsync
    real_replace = os.replace

    def recording_fsync(fd):
        events.append(("fsync", os.fstat(fd).st_ino))
        return real_fsync(fd)

    def recording_replace(src, dst, *args, **kwargs):
        events.append(("replace", os.stat(src).st_ino))
        return real_replace(src, dst, *args, **kwargs)

    def recording_fsync_dir(directory):
        events.append(("fsync_dir", directory))

    def recording_fullfsync(fd, cmd, arg=0):
        # On darwin the tmp flush is F_FULLFSYNC via fcntl; elsewhere os.fsync.
        # Record either path as the "fsync" event so the ordering contract is
        # platform-independent.
        events.append(("fsync", os.fstat(fd).st_ino))
        return 0

    monkeypatch.setattr(os, "fsync", recording_fsync)
    monkeypatch.setattr(fcntl, "F_FULLFSYNC", 51, raising=False)
    monkeypatch.setattr(fcntl, "fcntl", recording_fullfsync)
    monkeypatch.setattr(os, "replace", recording_replace)
    monkeypatch.setattr(user_store_mod, "fsync_dir", recording_fsync_dir, raising=False)

    users_file = tmp_path / "users.json"
    users = {"u1": {"email": "a@example.com"}}
    user_store_mod.save_users_to(users_file, users, lambda payload: (payload, False))

    assert [kind for kind, _ in events] == ["fsync", "replace", "fsync_dir"], events
    fsynced_ino = events[0][1]
    replaced_ino = events[1][1]
    assert fsynced_ino == replaced_ino, "the fsync must target the tmp file that is renamed"
    assert events[2][1] == tmp_path
    assert json.loads(users_file.read_text()) == users


# ===========================================================================
# save_users_to macOS F_FULLFSYNC durability (#3865)
# ===========================================================================

_FAKE_F_FULLFSYNC = 51


def _save_with_fsync_patches(tmp_path, monkeypatch, fcntl_impl=None):
    import fcntl

    fsync_calls: list[int] = []
    fcntl_calls: list[tuple[int, int, object]] = []
    real_replace = os.replace
    events: list[str] = []

    def recording_fcntl(fd, cmd, arg=0):
        fcntl_calls.append((fd, cmd, arg))
        events.append("fcntl")
        if fcntl_impl is not None:
            return fcntl_impl(fd, cmd, arg)
        return 0

    def recording_fsync(fd):
        fsync_calls.append(fd)
        events.append("fsync")

    def recording_replace(src, dst, *args, **kwargs):
        events.append("replace")
        return real_replace(src, dst, *args, **kwargs)

    monkeypatch.setattr(fcntl, "F_FULLFSYNC", _FAKE_F_FULLFSYNC, raising=False)
    monkeypatch.setattr(fcntl, "fcntl", recording_fcntl)
    monkeypatch.setattr(os, "fsync", recording_fsync)
    monkeypatch.setattr(os, "replace", recording_replace)
    monkeypatch.setattr(user_store_mod, "fsync_dir", lambda directory: None)

    users_file = tmp_path / "users.json"
    users = {"u1": {"email": "a@example.com"}}
    user_store_mod.save_users_to(users_file, users, lambda payload: (payload, False))
    return events, fcntl_calls, fsync_calls, users_file, users


def test_save_users_to_flushes_tmp_with_fullfsync_before_replace(tmp_path, monkeypatch):
    events, fcntl_calls, fsync_calls, users_file, users = _save_with_fsync_patches(tmp_path, monkeypatch)

    assert events == ["fcntl", "replace"], events
    assert len(fcntl_calls) == 1
    _fd, cmd, arg = fcntl_calls[0]
    assert cmd == _FAKE_F_FULLFSYNC
    assert arg == 0
    assert fsync_calls == [], "F_FULLFSYNC replaces os.fsync on darwin"
    assert json.loads(users_file.read_text()) == users


def test_save_users_to_falls_back_to_os_fsync_when_fullfsync_raises(tmp_path, monkeypatch):
    import errno

    def unsupported(fd, cmd, arg):
        raise OSError(errno.ENOTTY, "F_FULLFSYNC unsupported")

    events, _, fsync_calls, users_file, users = _save_with_fsync_patches(tmp_path, monkeypatch, fcntl_impl=unsupported)

    assert events == ["fcntl", "fsync", "replace"], events
    assert len(fsync_calls) == 1
    assert json.loads(users_file.read_text()) == users


def test_save_users_to_uses_os_fsync_when_fullfsync_absent(tmp_path, monkeypatch):
    import fcntl

    monkeypatch.delattr(fcntl, "F_FULLFSYNC", raising=False)
    fsync_calls: list[int] = []
    fcntl_calls: list[object] = []
    monkeypatch.setattr(fcntl, "fcntl", lambda fd, cmd, arg=0: fcntl_calls.append(cmd) or 0)
    monkeypatch.setattr(os, "fsync", lambda fd: fsync_calls.append(fd))
    monkeypatch.setattr(user_store_mod, "fsync_dir", lambda directory: None)

    users_file = tmp_path / "users.json"
    user_store_mod.save_users_to(users_file, {"u1": {}}, lambda payload: (payload, False))

    assert fcntl_calls == []
    assert len(fsync_calls) == 1
