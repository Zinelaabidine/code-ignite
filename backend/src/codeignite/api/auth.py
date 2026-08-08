"""Cognito access-token verification for the API — stage 3 of
`docs/code-playground-implementation-plan.md`.

Verifies the *access* token, not the ID token: the ID token is about who the
user is, for the UI; the access token is the API credential and carries
`client_id` and `scope`. The frontend sends
`Authorization: Bearer <accessToken>`.

`PyJWKClient` keeps its own in-process cache of the JWKS keyed by `kid`, so
constructing it once at module import time (rather than per request) is what
satisfies "do not fetch it per request".
"""

from typing import Any

import jwt
from fastapi import Header, HTTPException
from fastapi.security.utils import get_authorization_scheme_param
from jwt import PyJWKClient

from codeignite.config import settings

_ISSUER = f"https://cognito-idp.{settings.aws_region}.amazonaws.com/{settings.cognito_user_pool_id}"
_JWKS_URL = f"{_ISSUER}/.well-known/jwks.json"

_jwks_client = PyJWKClient(_JWKS_URL)


def _unauthenticated() -> HTTPException:
    # A fresh instance per call, not a shared module-level constant: raising
    # `... from error` mutates the exception's `__cause__`, and concurrent
    # requests sharing one instance could race on that mutation.
    return HTTPException(status_code=401, detail="Not authenticated")


def _decode(token: str) -> dict[str, Any]:
    signing_key = _jwks_client.get_signing_key_from_jwt(token)
    claims: dict[str, Any] = jwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        issuer=_ISSUER,
        # Access tokens carry no `aud` claim — Cognito puts `client_id` there
        # instead, checked explicitly below — so audience verification stays
        # off rather than being pointed at a claim that isn't present.
        options={"verify_aud": False, "require": ["exp", "iss", "sub"]},
    )
    return claims


def get_current_sub(authorization: str | None = Header(default=None)) -> str:
    """FastAPI dependency: verifies the bearer token and returns its `sub`.

    401 on any failure, with no detail about which check failed — missing
    header, expired token, wrong pool, and an ID token presented instead of
    an access token all look identical from the outside. Distinguishing them
    in the response would hand an attacker a probe for free.
    """
    scheme, token = get_authorization_scheme_param(authorization or "")
    if scheme.lower() != "bearer" or not token:
        raise _unauthenticated()

    try:
        claims = _decode(token)
    except jwt.PyJWTError as error:
        raise _unauthenticated() from error

    if claims.get("token_use") != "access" or claims.get("client_id") != settings.cognito_client_id:
        raise _unauthenticated()

    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise _unauthenticated()
    return sub
