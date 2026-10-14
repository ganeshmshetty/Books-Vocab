"""Translate service — LLM-backed quick/phrase/explain flows.

Singleflight limitation: `_INFLIGHT` is a process-local dict, so dedup applies
only within a single worker. In multi-worker deploys (uvicorn --workers N,
gunicorn, etc.) each worker maintains its own in-flight map; the worst case
is N concurrent LLM calls for the same input (one per worker), still bounded
and far cheaper than per-request fan-out. Cross-worker dedup would require a
shared coordinator (Redis SETNX + pub/sub, etc.) and is intentionally out of
scope here.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import time
from collections.abc import Callable
from typing import Any

from . import translate_log
from .exceptions import ExternalServiceError

# In-flight request dedup ("singleflight"). When multiple coroutines fire
# the same translate request before the first one finishes, they share the
# first coroutine's future instead of each calling the LLM. The key is the
# full cache key (user + word + ctx hash + langs + op + model), so different
# users / inputs never collide. Entries are removed in `finally` so a failed
# call doesn't poison subsequent attempts.
_INFLIGHT: dict[tuple, asyncio.Future] = {}

# Followers awaiting the leader's future cap their wait at this many seconds.
# Aligned with typical LLM p99 latency (Gemini flash-lite ~2-10s, with headroom
# for retries inside the SDK). A hung leader (network stall, infinite retry)
# would otherwise cascade-hang every follower indefinitely. On timeout the
# follower raises TimeoutError; the request fails fast and the client retries.
_INFLIGHT_WAIT_TIMEOUT_S: float = 120.0

from .api_models import ExplainResponse, QuickTranslateResponse, TranslateRequest
from .languages import LANGUAGE_NAMES as SUPPORTED_LANGUAGES
from .languages import SUPPORTED_SOURCE_LANGS, SUPPORTED_TARGET_LANGS
from .vocab_shared import _normalize_pos

_MARKED_SPAN = re.compile(r"\*\*.+?\*\*")


def _boundary_pattern(term: str) -> re.Pattern[str]:
    return re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE)


def _context_around_word(context: str, word: str, max_len: int = 300) -> str:
    """Truncate context centered on the target word."""
    if len(context) <= max_len:
        return context
    span = _MARKED_SPAN.search(context)
    if span:
        pos, word_len = span.start(), span.end() - span.start()
    else:
        match = _boundary_pattern(word).search(context)
        if not match:
            return context[:max_len]
        pos, word_len = match.start(), len(word)
    half = (max_len - word_len) // 2
    start = max(0, pos - half)
    end = min(len(context), pos + word_len + half)
    return context[start:end].strip()


def _compute_context_hash(context: str) -> str:
    return hashlib.sha256((context or "").encode()).hexdigest()[:16]


def resolve_translation_langs(req: TranslateRequest, user: dict[str, Any]) -> tuple[str, str]:
    """Resolve source/target languages from request → user config → defaults."""
    source = req.source_lang
    target = req.target_lang

    user_config = user.get("config", {})
    translation_config = user_config.get("translation", {}) if isinstance(user_config, dict) else {}

    if not source:
        source = translation_config.get("source_lang", "en")
    if not target:
        target = translation_config.get("target_lang", "zh-Hant")

    if source not in SUPPORTED_SOURCE_LANGS:
        source = "en"
    if target not in SUPPORTED_TARGET_LANGS:
        target = "zh-Hant"

    return source, target


def quick_translate_prompt(req: TranslateRequest, source_lang: str, target_lang: str, ctx: str) -> str:
    src_name = SUPPORTED_LANGUAGES.get(source_lang, "English")
    tgt_name = SUPPORTED_LANGUAGES.get(target_lang, "Traditional Chinese")
    return f'''Translate from {src_name} to {tgt_name}. Provide translation, POS, and lemma (root form).
POS options: n. / v. / adj. / adv. / conj. / prep.
Word: "{req.word}"
Context: "{ctx}"

Translation (t) rules:
- Must be {tgt_name} (use 繁體中文 characters, never 简体)
- adj. translation must end with「的」(e.g. 輝煌的, 虔誠的)
- adv. translation must end with「地」(e.g. 沉思地, 端莊地)

Lemma (r) rules:
- Must be a valid {src_name} dictionary word
- No cross-POS derivation (adjective lemma stays adjective, not its derived noun)
- Verb inflections → base form (e.g. hurrying→hurry, gazed→gaze)
- Plural nouns → singular (e.g. berries→berry); if no singular exists, return original
- If adjective/adverb is already base form, r = original word
- When uncertain, r = original word; never invent non-existent words

Output pure JSON (no Markdown): {{ "t": "...", "p": "...", "r": "..." }}'''


def phrase_translate_prompt(req: TranslateRequest, source_lang: str, target_lang: str, ctx: str) -> str:
    src_name = SUPPORTED_LANGUAGES.get(source_lang, "English")
    tgt_name = SUPPORTED_LANGUAGES.get(target_lang, "Traditional Chinese")
    return f'''Translate the following {src_name} phrase/expression into {tgt_name} (use 繁體中文, never 简体).
Phrase: "{req.word}"
Context: "{ctx}"
Output pure JSON (no Markdown): {{ "t": "..." }}'''


def explain_translate_prompt(req: TranslateRequest, source_lang: str, target_lang: str, ctx: str) -> str:
    src_name = SUPPORTED_LANGUAGES.get(source_lang, "English")
    tgt_name = SUPPORTED_LANGUAGES.get(target_lang, "Traditional Chinese")
    return f'''Explain what "{req.word}" means in the given context, then briefly break down the {src_name} components/structure. 1-2 sentences max, in {tgt_name} (use 繁體中文 characters, never 简体).

Word: "{req.word}"
Context: "{ctx}"
Output pure JSON (no Markdown): {{ "e": "..." }}'''


def _parse_json_payload(raw: str | None) -> dict[str, Any]:
    try:
        data = json.loads(raw or "{}")
    except json.JSONDecodeError:
        # raw is necessarily truthy here: json.loads(raw or "{}") only raises
        # for a non-empty malformed string (None/"" parse cleanly to {}).
        logging.getLogger("kg").warning("Failed to parse JSON payload: %s", raw[:200])
        return {}
    if isinstance(data, list):
        data = data[0] if data else {}
    if not isinstance(data, dict):
        return {}
    return data


def _validate_translation_payload(data: dict[str, Any], *, required_field: str, operation: str) -> None:
    value = data.get(required_field)
    if not isinstance(value, str) or not value.strip():
        raise ExternalServiceError(f"{operation}/invalid_response")
    # Optional fields (translate_quick p/r): absent or None is fine, anything
    # else must be a string so a malformed value is never cached or served.
    for optional_field in ("p", "r"):
        if not isinstance(data.get(optional_field), str | None):
            raise ExternalServiceError(f"{operation}/invalid_response")


async def _run_llm_translate(
    *,
    req: TranslateRequest,
    user: dict[str, Any],
    llm: Any,
    model: str,
    prompt_fn: Callable[[TranslateRequest, str, str, str], str],
    operation: str,
    required_field: str,
    logger: logging.Logger | None = None,
) -> dict[str, Any]:
    """Common LLM translate flow: resolve langs -> cache check -> call -> parse -> record."""
    source_lang, target_lang = resolve_translation_langs(req, user)
    ctx = _context_around_word(req.context, req.word)
    word_key = req.word.strip().lower()
    ctx_hash = _compute_context_hash(ctx)

    # Cache lookup — model is part of the key (see translate_log.lookup docstring).
    # translate_log takes its lock and runs SQLite: keep it off the event loop (#3829).
    cached = await asyncio.to_thread(
        translate_log.lookup, word_key, ctx_hash, source_lang, target_lang, operation, model
    )
    cached_data: dict[str, Any] | None = None
    if cached is not None:
        cached_data = _parse_json_payload(cached)
        try:
            _validate_translation_payload(cached_data, required_field=required_field, operation=operation)
        except ExternalServiceError:
            # Poisoned row: treat as a miss so a valid LLM response overwrites it.
            logging.getLogger("kg").warning("%s: invalid cached payload for %r, refetching", operation, word_key)
            cached_data = None
    if cached_data is not None:
        # Record precise hit counter for admin observability. Short-circuits
        # never reach record(); without this they'd be invisible to metrics.
        try:
            await asyncio.to_thread(
                translate_log.record_cache_hit,
                user_id=getattr(llm, "user_id", None),
                operation=operation,
                word=word_key,
                context_hash=ctx_hash,
                source_lang=source_lang,
                target_lang=target_lang,
                model=model,
            )
        except Exception:  # noqa: BLE001 — observability must never break translation
            if logger:
                logger.exception("record_cache_hit failed (non-fatal)")
        return cached_data

    # In-flight dedup: if an identical request is already running for this
    # user, await its future instead of firing a second LLM call. Keyed by
    # the full cache key so different users / inputs never share state.
    inflight_key = (
        getattr(llm, "user_id", None),
        word_key,
        ctx_hash,
        source_lang,
        target_lang,
        operation,
        model,
    )
    existing = _INFLIGHT.get(inflight_key)
    if existing is not None:
        # Bound the follower's wait so a hung leader (LLM stall, frozen
        # network) doesn't cascade-hang every concurrent caller. TimeoutError
        # surfaces to the client as a normal failure; the leader entry is
        # cleaned up by its own finally block.
        return await asyncio.wait_for(asyncio.shield(existing), timeout=_INFLIGHT_WAIT_TIMEOUT_S)

    loop = asyncio.get_running_loop()
    fut: asyncio.Future = loop.create_future()
    _INFLIGHT[inflight_key] = fut
    try:
        # LLM call with latency tracking
        t0 = time.monotonic()
        response = await llm.chat_async(
            operation,
            model=model,
            messages=[{"role": "user", "content": prompt_fn(req, source_lang, target_lang, ctx)}],
            temperature=0.3,
            response_format={"type": "json_object"},
        )
        latency_ms = int((time.monotonic() - t0) * 1000)

        if not response.choices:
            if logger:
                logger.error("%s: Gemini returned empty choices. Response: %s", operation, repr(response)[:500])
            raise ExternalServiceError(f"{operation}/empty_response")

        raw = response.choices[0].message.content
        parsed = _parse_json_payload(raw)
        _validate_translation_payload(parsed, required_field=required_field, operation=operation)

        # Only cache non-empty, meaningful responses
        if raw and parsed and any(parsed.values()):
            translate_log.record(
                user_id=llm.user_id,
                operation=operation,
                word=word_key,
                context=ctx,
                context_hash=ctx_hash,
                source_lang=source_lang,
                target_lang=target_lang,
                response_raw=raw,
                latency_ms=latency_ms,
                model=model,
            )

        fut.set_result(parsed)
        return parsed
    except BaseException as exc:
        if not fut.done():
            fut.set_exception(exc)
        # Followers still receive the exception via ``await``. Mark it retrieved
        # so a leader-only failure doesn't make asyncio log "Future exception
        # was never retrieved" at ERROR when ``fut`` is garbage-collected.
        if not fut.cancelled():
            fut.exception()
        raise
    finally:
        # Remove only if it's still our entry (defensive against any
        # future reentrancy). Followers awaiting `fut` already have the
        # reference; popping the dict doesn't affect them.
        if _INFLIGHT.get(inflight_key) is fut:
            _INFLIGHT.pop(inflight_key, None)


async def run_quick_translate(
    req: TranslateRequest,
    user: dict[str, Any],
    *,
    llm: Any,
    logger: logging.Logger,
    model: str = "gemini-2.5-flash-lite",
) -> QuickTranslateResponse:
    data = await _run_llm_translate(
        req=req,
        user=user,
        llm=llm,
        model=model,
        prompt_fn=quick_translate_prompt,
        operation="translate_quick",
        required_field="t",
        logger=logger,
    )
    return QuickTranslateResponse(t=data.get("t", ""), p=_normalize_pos(data.get("p")), r=data.get("r"))


async def run_phrase_translate(
    req: TranslateRequest,
    user: dict[str, Any],
    *,
    llm: Any,
    logger: logging.Logger | None = None,
    model: str = "gemini-2.5-flash-lite",
) -> dict[str, str]:
    data = await _run_llm_translate(
        req=req,
        user=user,
        llm=llm,
        model=model,
        prompt_fn=phrase_translate_prompt,
        operation="translate_phrase",
        required_field="t",
        logger=logger,
    )
    return {"t": data.get("t", "")}


async def run_explain_translate(
    req: TranslateRequest,
    user: dict[str, Any],
    *,
    llm: Any,
    logger: logging.Logger | None = None,
    model: str = "gemini-2.5-flash-lite",
) -> ExplainResponse:
    data = await _run_llm_translate(
        req=req,
        user=user,
        llm=llm,
        model=model,
        prompt_fn=explain_translate_prompt,
        operation="translate_explain",
        required_field="e",
        logger=logger,
    )
    return ExplainResponse(e=data.get("e", ""))
