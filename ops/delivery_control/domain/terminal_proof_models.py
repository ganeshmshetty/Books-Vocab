"""Exact terminal proof value objects for merged delivery lanes."""

from __future__ import annotations

from dataclasses import dataclass

from .errors import InvalidReceipt
from .validation_models import _require_sha, _require_text


@dataclass(frozen=True)
class MergedPullRequestProof:
    """Exact GitHub observation authorizing a terminal merged disposition."""

    lane_id: str
    pr_number: int
    branch: str
    head_sha: str
    base_branch: str = "main"
    pr_state: str = "MERGED"
    # Set only when the merged PR head moved past the lane tip (GitHub "Update
    # branch"); head_sha stays the lane tip the registry terminalizes.
    merged_head_sha: str | None = None

    def __post_init__(self) -> None:
        _require_text("lane_id", self.lane_id)
        _require_text("branch", self.branch)
        _require_sha("head_sha", self.head_sha)
        if type(self.pr_number) is not int or self.pr_number <= 0:
            raise InvalidReceipt("pr_number must be a positive integer")
        if self.base_branch != "main" or self.pr_state != "MERGED":
            raise InvalidReceipt("merged PR proof must target main and be MERGED")
        if self.merged_head_sha is not None:
            _require_sha("merged_head_sha", self.merged_head_sha)
            if self.merged_head_sha == self.head_sha:
                raise InvalidReceipt("merged_head_sha must differ from head_sha")
