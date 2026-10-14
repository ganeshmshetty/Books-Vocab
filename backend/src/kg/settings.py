from __future__ import annotations

import logging
import math
import os
from dataclasses import dataclass
from pathlib import Path

_logger = logging.getLogger(__name__)

_JWT_SECRET_MIN_LENGTH = 32
_JWT_SECRET_PLACEHOLDERS = frozenset({"your-secret-key-change-in-production", "changeme", "change-me", "secret"})

DEFAULT_PUBLIC_WEB_BASE_URL = "https://wordnexus.lol"
_GOOGLE_WEB_CALLBACK_PATH = "/auth/web/google/callback"
_APPLE_WEB_CALLBACK_PATH = "/auth/web/apple/callback"

DEFAULT_API_RATE_LIMIT = 60
DEFAULT_TRANSLATE_RATE_LIMIT = 20
DEFAULT_ADMIN_LOGIN_RATE_LIMIT = 5
MAX_RATE_LIMIT_REQUESTS = 10_000

_DEFAULT_CORS: tuple[str, ...] = (
    DEFAULT_PUBLIC_WEB_BASE_URL,
    "http://localhost:8000",
    "http://127.0.0.1:8000",
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost:3000",
    "http://127.0.0.1:3000",
)


@dataclass(frozen=True)
class RateLimitSettingsSnapshot:
    """Validated rate-limit configuration independent of auth bootstrap."""

    api_rate_limit: int = DEFAULT_API_RATE_LIMIT
    translate_rate_limit: int = DEFAULT_TRANSLATE_RATE_LIMIT
    admin_login_rate_limit: int = DEFAULT_ADMIN_LOGIN_RATE_LIMIT


@dataclass(frozen=True)
class KGSettings:
    data_dir: Path
    jwt_secret: str
    public_web_base_url: str = DEFAULT_PUBLIC_WEB_BASE_URL
    jwt_algorithm: str = "HS256"
    jwt_expiry_minutes: int = 60 * 24 * 7
    google_client_id: str = ""
    google_client_secret: str = ""
    google_redirect_uri: str = DEFAULT_PUBLIC_WEB_BASE_URL + _GOOGLE_WEB_CALLBACK_PATH
    apple_bundle_id: str = "com.Max0228.BooksBrowser"
    apple_service_id: str = "com.Max0228.BooksAndVocab.web"
    # Sign in with Apple token revocation (#3815). Enabled only when all three are
    # set; the client_id is apple_bundle_id. See kg/apple_token_revocation.py.
    apple_siwa_team_id: str | None = None
    apple_siwa_key_id: str | None = None
    apple_siwa_private_key_path: Path | None = None
    app_store_allow_unsigned_sync: bool = False
    app_store_allow_unsigned_notifications: bool = False
    admin_token: str = ""
    admin_password: str = ""

    # Quota (USD)
    pro_daily_limit_usd: float = 0.30
    free_daily_limit_usd: float = 0.03

    # Rate limiting — anonymous (no-auth) requests are keyed off the client IP
    # extracted from X-Forwarded-For. This is the number of TRUSTED proxy hops
    # in front of the app: the key is taken from the Nth-from-end XFF segment.
    # Default 1 matches the current single-layer bare Caddy deployment, which
    # appends the real client IP to the END of XFF (so [-1] is the real IP).
    # Set to N+1 only if N additional trusted proxies (CDN/ALB) are placed in
    # front of Caddy. See docs/reference/host_topology.md.
    rate_limit_trusted_hops: int = 1
    api_rate_limit: int = DEFAULT_API_RATE_LIMIT
    translate_rate_limit: int = DEFAULT_TRANSLATE_RATE_LIMIT
    admin_login_rate_limit: int = DEFAULT_ADMIN_LOGIN_RATE_LIMIT

    # LLM
    embedding_model: str = "gemini-embedding-2-preview"
    embedding_dim: int = 3072
    gemini_temperature: float = 0.3
    judge_temperature: float = 0.1
    # Minimum confidence for a judge link to be accepted. Lower this when
    # switching to a lower-calibrated judge model to avoid silently rejecting
    # all links. Default 0.7 preserves prior hardcoded behavior.
    judge_confidence_threshold: float = 0.7

    # Graph
    similarity_threshold: float = 0.70
    candidate_k: int = 20

    # Vocab
    max_batch_size: int = 500
    max_word_length: int = 200

    # Pure external lexical lookup is rollout-gated and never mutates cards.
    dictionary_lookup_enabled: bool = False
    dictionary_provider_default: str = "free_dictionary"
    dictionary_cache_ttl_days: int = 30
    dictionary_negative_cache_ttl_hours: int = 24

    # CORS
    cors_origins: tuple[str, ...] = _DEFAULT_CORS

    # Podcast storage backend.
    # When `podcast_bucket` is set, audio + subtitle reads go to S3-compatible
    # object storage (Lightsail Object Storage in prod). When unset, the
    # backend falls back to the on-disk layout under `data_dir/podcasts/` —
    # this preserves dev-time iteration and provides a transition window
    # before older series are re-uploaded in m4a form.
    podcast_bucket: str | None = None
    podcast_bucket_region: str = "ap-northeast-1"
    # Optional S3-compatible endpoint URL. Standard AWS S3 leaves this empty;
    # Lightsail Object Storage works with the default region-derived URL too,
    # but the env var is wired through for custom endpoints (e.g. R2 / minio
    # during local testing).
    podcast_bucket_endpoint_url: str | None = None

    # Book asset storage backend (Architecture PR #7).
    # When `library_bucket` is set, book assets (EPUB/PDF/TXT/MD) are uploaded
    # to / downloaded from S3-compatible object storage via presigned URLs.
    # When unset (dev / privacy-preserving default), assets stay client-local
    # (CloudKit / on-device) and the upload endpoint declares them local-only.
    library_bucket: str | None = None
    library_bucket_region: str = "ap-northeast-1"
    library_bucket_endpoint_url: str | None = None
    # Per-asset upload cap (bytes). Large enough for full EPUB/PDF books, small
    # enough to reject obvious abuse. Default 200 MiB.
    library_asset_max_bytes: int = 200 * 1024 * 1024

    # Shared decks (Explore) — a single GLOBAL catalog store lives at
    # ``data_dir/shared_decks.db`` (outside users/<uid>/). Only official decks
    # exist in Phase 1-2; community publishing (the write path) is Phase 3 and
    # is gated OFF here day one. Caps are wired now (forward-compat) so opening
    # that path later needs no schema/settings change. See §6.5 of
    # docs/plans/2026-07-09-shared-decks-library.md.
    shared_decks_publish_enabled: bool = False
    max_cards_per_deck: int = 2000
    shared_decks_publish_rate_limit_per_day: int = 20
    shared_decks_report_auto_hide_threshold: int = 5
    shared_decks_rating_min_count_for_sort: int = 3

    @property
    def users_file(self) -> Path:
        return self.data_dir / "users.json"

    @property
    def users_lock_file(self) -> Path:
        return self.data_dir / "users.json.lock"

    @property
    def podcasts_dir(self) -> Path:
        return self.data_dir / "podcasts"

    @property
    def shared_decks_path(self) -> Path:
        return self.data_dir / "shared_decks.db"

    @property
    def app_store_notifications_file(self) -> Path:
        return self.data_dir / "app_store_notifications.ndjson"

    @property
    def apple_redirect_uri(self) -> str:
        return self.public_web_base_url.rstrip("/") + _APPLE_WEB_CALLBACK_PATH


def _env_truthy(name: str) -> bool:
    # ops/env_drift.py `env_flag_truthy` must stay a superset of this (env-check);
    # ops/tests/test_env_check.py pins the parity.
    return os.getenv(name, "").strip().lower() in {"1", "true", "yes"}


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        value = float(raw)
    except ValueError:
        _logger.warning(
            "Env var %s=%r is not a valid float; falling back to default %s.",
            name,
            raw,
            default,
        )
        _logger.warning("Silently handled exception; using fallback response", exc_info=True)
        return default
    if not math.isfinite(value):
        _logger.warning(
            "Env var %s=%r is not a finite float; falling back to default %s.",
            name,
            raw,
            default,
        )
        return default
    return value


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        _logger.warning(
            "Env var %s=%r is not a valid int; falling back to default %s.",
            name,
            raw,
            default,
        )
        _logger.warning("Silently handled exception; using fallback response", exc_info=True)
        return default


def _env_rate_limit(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        _logger.warning(
            "Env var %s=%r is not a valid rate-limit int; falling back to default %s.",
            name,
            raw,
            default,
        )
        return default
    if not 0 < value <= MAX_RATE_LIMIT_REQUESTS:
        _logger.warning(
            "Env var %s=%r is outside the supported range 1..%s; falling back to default %s.",
            name,
            raw,
            MAX_RATE_LIMIT_REQUESTS,
            default,
        )
        return default
    return value


def load_rate_limit_settings() -> RateLimitSettingsSnapshot:
    """Load only the validated rate-limit snapshot.

    The limiter module is imported before the API module loads its full
    settings. Keep this narrow so importing a generic limiter does not require
    unrelated startup secrets such as JWT_SECRET.
    """
    return RateLimitSettingsSnapshot(
        api_rate_limit=_env_rate_limit("API_RATE_LIMIT", DEFAULT_API_RATE_LIMIT),
        translate_rate_limit=_env_rate_limit("TRANSLATE_RATE_LIMIT", DEFAULT_TRANSLATE_RATE_LIMIT),
        admin_login_rate_limit=_env_rate_limit("ADMIN_LOGIN_RATE_LIMIT", DEFAULT_ADMIN_LOGIN_RATE_LIMIT),
    )


def _apple_siwa_env() -> tuple[str | None, str | None, Path | None]:
    """Read the Sign in with Apple revocation config; log one line when it is off (#3815)."""
    team_id = os.getenv("APPLE_SIWA_TEAM_ID") or None
    key_id = os.getenv("APPLE_SIWA_KEY_ID") or None
    key_path = os.getenv("APPLE_SIWA_PRIVATE_KEY_PATH") or None
    missing = [
        name
        for name, value in (
            ("APPLE_SIWA_TEAM_ID", team_id),
            ("APPLE_SIWA_KEY_ID", key_id),
            ("APPLE_SIWA_PRIVATE_KEY_PATH", key_path),
        )
        if value is None
    ]
    if missing:
        _logger.info("SIWA token revocation disabled (missing: %s)", ", ".join(missing))
    return team_id, key_id, (Path(key_path) if key_path else None)


def load_settings() -> KGSettings:
    default_data_dir = Path(__file__).resolve().parent.parent.parent / "data"

    jwt_secret = os.getenv("JWT_SECRET")
    if not jwt_secret:
        raise RuntimeError("JWT_SECRET env var is required. Set it in your .env file.")
    if jwt_secret.strip().lower() in _JWT_SECRET_PLACEHOLDERS:
        raise RuntimeError(
            "JWT_SECRET is a placeholder value; generate a unique secret: "
            'python -c "import secrets; print(secrets.token_urlsafe(48))"'
        )
    if len(jwt_secret) < _JWT_SECRET_MIN_LENGTH:
        raise RuntimeError(
            f"JWT_SECRET must be at least {_JWT_SECRET_MIN_LENGTH} characters; generate one: "
            'python -c "import secrets; print(secrets.token_urlsafe(48))"'
        )

    app_store_allow_unsigned_notifications = _env_truthy("APP_STORE_ALLOW_UNSIGNED_NOTIFICATIONS")
    if app_store_allow_unsigned_notifications:
        _logger.warning(
            "APP_STORE_ALLOW_UNSIGNED_NOTIFICATIONS is ON — signature verification disabled. DO NOT use in production."
        )

    app_store_allow_unsigned_sync = _env_truthy("APP_STORE_ALLOW_UNSIGNED_SYNC")
    if app_store_allow_unsigned_sync:
        _logger.warning(
            "APP_STORE_ALLOW_UNSIGNED_SYNC is ON — signature verification disabled. DO NOT use in production."
        )

    rate_limit_settings = load_rate_limit_settings()
    siwa_team_id, siwa_key_id, siwa_key_path = _apple_siwa_env()

    public_web_base_url = os.getenv("PUBLIC_WEB_BASE_URL", DEFAULT_PUBLIC_WEB_BASE_URL).rstrip("/")

    return KGSettings(
        data_dir=Path(os.getenv("KG_DATA_DIR", str(default_data_dir))),
        jwt_secret=jwt_secret,
        public_web_base_url=public_web_base_url,
        embedding_model=os.getenv("EMBEDDING_MODEL", "gemini-embedding-2-preview"),
        embedding_dim=_env_int("EMBEDDING_DIM", 3072),
        google_client_id=os.getenv("GOOGLE_CLIENT_ID", ""),
        google_client_secret=os.getenv("GOOGLE_CLIENT_SECRET", ""),
        google_redirect_uri=os.getenv("GOOGLE_REDIRECT_URI", public_web_base_url + _GOOGLE_WEB_CALLBACK_PATH),
        apple_bundle_id=os.getenv("APPLE_BUNDLE_ID", "com.Max0228.BooksBrowser"),
        apple_service_id=os.getenv("APPLE_SERVICE_ID", "com.Max0228.BooksAndVocab.web"),
        apple_siwa_team_id=siwa_team_id,
        apple_siwa_key_id=siwa_key_id,
        apple_siwa_private_key_path=siwa_key_path,
        app_store_allow_unsigned_sync=app_store_allow_unsigned_sync,
        app_store_allow_unsigned_notifications=app_store_allow_unsigned_notifications,
        admin_token=os.getenv("ADMIN_TOKEN", ""),
        admin_password=os.getenv("ADMIN_PASSWORD", ""),
        pro_daily_limit_usd=_env_float("PRO_DAILY_LIMIT_USD", 0.30),
        free_daily_limit_usd=_env_float("FREE_DAILY_LIMIT_USD", 0.03),
        rate_limit_trusted_hops=_env_int("RATE_LIMIT_TRUSTED_HOPS", 1),
        api_rate_limit=rate_limit_settings.api_rate_limit,
        translate_rate_limit=rate_limit_settings.translate_rate_limit,
        admin_login_rate_limit=rate_limit_settings.admin_login_rate_limit,
        judge_confidence_threshold=_env_float("JUDGE_CONFIDENCE_THRESHOLD", 0.7),
        dictionary_lookup_enabled=_env_truthy("DICTIONARY_LOOKUP_ENABLED"),
        dictionary_provider_default=os.getenv("DICTIONARY_PROVIDER_DEFAULT", "free_dictionary"),
        dictionary_cache_ttl_days=_env_int("DICTIONARY_CACHE_TTL_DAYS", 30),
        dictionary_negative_cache_ttl_hours=_env_int("DICTIONARY_NEGATIVE_CACHE_TTL_HOURS", 24),
        cors_origins=tuple(
            o.strip()
            for o in os.getenv(
                "CORS_ORIGINS",
                ",".join(_DEFAULT_CORS),
            ).split(",")
            if o.strip()
        ),
        podcast_bucket=(os.getenv("PODCAST_BUCKET") or None),
        podcast_bucket_region=os.getenv("PODCAST_BUCKET_REGION", "ap-northeast-1"),
        podcast_bucket_endpoint_url=(os.getenv("PODCAST_BUCKET_ENDPOINT_URL") or None),
        library_bucket=(os.getenv("LIBRARY_BUCKET") or None),
        library_bucket_region=os.getenv("LIBRARY_BUCKET_REGION", "ap-northeast-1"),
        library_bucket_endpoint_url=(os.getenv("LIBRARY_BUCKET_ENDPOINT_URL") or None),
        library_asset_max_bytes=_env_int("LIBRARY_ASSET_MAX_BYTES", 200 * 1024 * 1024),
        shared_decks_publish_enabled=_env_truthy("SHARED_DECKS_PUBLISH_ENABLED"),
        max_cards_per_deck=_env_int("MAX_CARDS_PER_DECK", 2000),
        shared_decks_publish_rate_limit_per_day=_env_int("SHARED_DECKS_PUBLISH_RATE_LIMIT_PER_DAY", 20),
        shared_decks_report_auto_hide_threshold=_env_int("SHARED_DECKS_REPORT_AUTO_HIDE_THRESHOLD", 5),
        shared_decks_rating_min_count_for_sort=_env_int("SHARED_DECKS_RATING_MIN_COUNT_FOR_SORT", 3),
    )
