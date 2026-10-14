"""Batch judgement response parsing."""

from __future__ import annotations

import json
import logging
import math

from ..graph import LinkKind
from .models import Judgement

logger = logging.getLogger(__name__)


def _all_parse_error(
    candidates: list[tuple[str, str, str]],
    raw_decisions: list[dict] | None,
) -> dict[str, None]:
    """Record a parse_error decision for every candidate and return all-None.

    Shared by the empty-content and JSON-decode-failure branches, which both
    fail the whole batch identically.
    """
    if raw_decisions is not None:
        for cid, _, _ in candidates:
            raw_decisions.append(
                {
                    "to_id": cid,
                    "verdict": "parse_error",
                    "confidence": 0.0,
                    "accepted": 0,
                    "reject_reason": "parse_error",
                    "reason": "",
                }
            )
    return {cid: None for cid, _, _ in candidates}


def _parse_batch_response(
    content: str | None,
    candidates: list[tuple[str, str, str]],
    *,
    raw_decisions: list[dict] | None = None,
    confidence_threshold: float = 0.7,
) -> dict[str, Judgement | None]:
    """Parse LLM batch response, matching back to candidate card_ids.

    Uses card_id-keyed matching (not word-based) to avoid duplicate word collisions.
    Response items matched by position (array order matches candidate order).
    """
    if not content:
        return _all_parse_error(candidates, raw_decisions)

    try:
        data = json.loads(content)
    except (json.JSONDecodeError, ValueError):
        logger.warning("Failed to parse batch judgement. Raw: %r", content[:200])
        return _all_parse_error(candidates, raw_decisions)

    # Unwrap: {"results": [...]} or bare array or single object
    if isinstance(data, dict):
        for key in ("results", "judgements", "items", "candidates"):
            if key in data and isinstance(data[key], list):
                data = data[key]
                break
        else:
            if "link" in data:
                data = [data]
            else:
                data = []
    if not isinstance(data, list):
        data = []

    # Build word→items fallback index for reorder detection. Keyed to a LIST
    # (not last-wins) so duplicate candidate words — the same word on distinct
    # cards across notebooks in one batch — each resolve to a DISTINCT response
    # item instead of silently collapsing onto the last one.
    _word_items: dict[str, list[dict]] = {}
    for item in data:
        if isinstance(item, dict):
            w = item.get("word", "")
            # Non-string word (list/dict/number) is unhashable or unmatchable: skip it (#3893).
            if isinstance(w, str) and w:
                _word_items.setdefault(w, []).append(item)

    # Track response items already assigned (by identity) so neither the
    # positional path nor the word fallback hands the same item to two
    # candidates — the core of the duplicate-word disambiguation.
    _consumed: set[int] = set()

    def _next_unconsumed(w: str) -> dict | None:
        for it in _word_items.get(w, ()):
            if id(it) not in _consumed:
                return it
        return None

    # Match by position first; cross-check word, fallback to word-keyed lookup
    results: dict[str, Judgement | None] = {}
    for i, (cid, word, _) in enumerate(candidates):
        item = None
        if i < len(data) and isinstance(data[i], dict):
            pos_item = data[i]
            pos_word = pos_item.get("word", "")
            # Non-string pos_word never equals a str candidate word, so it falls through to
            # the word-keyed fallback instead of raising on the comparison path (#3893).
            if (pos_word == "" or pos_word == word) and id(pos_item) not in _consumed:
                item = pos_item  # positional match confirmed (and still free)
            else:
                # Positional mismatch (or already taken) — use word-keyed fallback,
                # consuming the next unused item for this word (FIFO).
                item = _next_unconsumed(word)
                if item:
                    logger.debug(
                        "Judge reorder detected: pos %d expected '%s' got '%s', used word fallback", i, word, pos_word
                    )
        else:
            item = _next_unconsumed(word)  # beyond response length, try word lookup

        if not item:
            if raw_decisions is not None:
                raw_decisions.append(
                    {
                        "to_id": cid,
                        "verdict": "no_response",
                        "confidence": 0.0,
                        "accepted": 0,
                        "reject_reason": "no_response",
                        "reason": "",
                    }
                )
            results[cid] = None
            continue
        # This response item now belongs to this candidate — even if it is later
        # rejected (low confidence / invalid kind), it must not be reused.
        _consumed.add(id(item))

        try:
            link_val = item.get("link", "not_applicable")
            confidence = float(item.get("confidence", 0.0))
            # Reject non-finite confidence (NaN/inf) outright: bare JSON `NaN`/
            # `Infinity` survives json.loads, and "NaN"/"inf" survive float(),
            # then clamp would silently coerce them to 1.0 and poison the graph.
            if not math.isfinite(confidence):
                raise ValueError(f"non-finite confidence: {confidence!r}")
            # Clamp finite values to [0, 1] — LLM may emit out-of-range values;
            # keep the link (don't reject) but never persist an invalid confidence.
            confidence = max(0.0, min(1.0, confidence))
            reason_val = item.get("reason", "")
            if not isinstance(reason_val, str):
                reason_val = ""
        except (ValueError, TypeError):
            if raw_decisions is not None:
                raw_decisions.append(
                    {
                        "to_id": cid,
                        "verdict": "parse_error",
                        "confidence": 0.0,
                        "accepted": 0,
                        "reject_reason": "parse_error",
                        "reason": "",
                    }
                )
            results[cid] = None
            continue

        if link_val == "not_applicable" or confidence < confidence_threshold:
            reject = "not_applicable" if link_val == "not_applicable" else "low_confidence"
            if raw_decisions is not None:
                raw_decisions.append(
                    {
                        "to_id": cid,
                        "verdict": link_val,
                        "confidence": confidence,
                        "accepted": 0,
                        "reject_reason": reject,
                        "reason": reason_val,
                    }
                )
            results[cid] = None
            continue

        try:
            LinkKind(link_val)
        except ValueError:
            if raw_decisions is not None:
                raw_decisions.append(
                    {
                        "to_id": cid,
                        "verdict": link_val,
                        "confidence": confidence,
                        "accepted": 0,
                        "reject_reason": "invalid_kind",
                        "reason": reason_val,
                    }
                )
            results[cid] = None
            continue

        if raw_decisions is not None:
            raw_decisions.append(
                {
                    "to_id": cid,
                    "verdict": link_val,
                    "confidence": confidence,
                    "accepted": 1,
                    "reject_reason": None,
                    "reason": reason_val,
                }
            )
        results[cid] = Judgement(link=link_val, confidence=confidence, reason=reason_val)

    # Any candidates beyond response length → None
    for cid, _, _ in candidates[len(data) :]:
        if raw_decisions is not None and cid not in {d["to_id"] for d in raw_decisions}:
            raw_decisions.append(
                {
                    "to_id": cid,
                    "verdict": "no_response",
                    "confidence": 0.0,
                    "accepted": 0,
                    "reject_reason": "no_response",
                    "reason": "",
                }
            )
        results.setdefault(cid, None)

    return results
