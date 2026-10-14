from __future__ import annotations

from fastapi import APIRouter, Request

from ..api_models import AuthVerifyRequest, AuthVerifyResponse
from ..apple_auth import verify_apple_token
from ..auth_handlers import auth_verify_response
from ..deps import _create_jwt_token, _resolve_and_link_user
from ..google_auth import verify_google_token

router = APIRouter(tags=["auth"])


@router.post("/auth/verify", response_model=AuthVerifyResponse)
async def auth_verify(req: AuthVerifyRequest, request: Request):
    settings = request.app.state.kg_settings
    load_users_fn = request.app.state.load_users
    save_users_fn = request.app.state.save_users

    def _jwt_token(user_id: str, provider: str) -> str:
        return _create_jwt_token(user_id, provider, settings=settings)

    def _link_user(provider_user_id: str, provider: str, email: str | None = None, hd: str | None = None) -> str:
        return _resolve_and_link_user(
            provider_user_id,
            provider,
            email,
            hd=hd,
            settings=settings,
            load_users_fn=load_users_fn,
            save_users_fn=save_users_fn,
        )

    return await auth_verify_response(
        req,
        google_client_id=settings.google_client_id,
        apple_bundle_id=settings.apple_bundle_id,
        jwt_expiry_minutes=settings.jwt_expiry_minutes,
        verify_google_token=verify_google_token,
        verify_apple_token=verify_apple_token,
        resolve_and_link_user=_link_user,
        create_jwt_token=_jwt_token,
    )
