"""Unit tests for `api/auth.py`'s Cognito access-token verification.

`_jwks_client.get_signing_key_from_jwt` is monkeypatched to return a locally
generated key instead of fetching a real JWKS over the network — per the
stage-3 checklist in `docs/code-playground-implementation-plan.md`: "Unit
tests use locally-signed JWTs against a fake JWKS — no network in CI."
"""

import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import HTTPException
from jwt import PyJWK
from jwt.algorithms import RSAAlgorithm

from codeignite.api import auth
from codeignite.config import settings

_PRIVATE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_SIGNING_KEY = PyJWK.from_json(RSAAlgorithm.to_jwk(_PRIVATE_KEY.public_key()), algorithm="RS256")

_VALID_ISSUER = (
    f"https://cognito-idp.{settings.aws_region}.amazonaws.com/{settings.cognito_user_pool_id}"
)


@pytest.fixture(autouse=True)
def _fake_jwks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(auth._jwks_client, "get_signing_key_from_jwt", lambda token: _SIGNING_KEY)


def _token(**overrides: object) -> str:
    now = int(time.time())
    claims: dict[str, object] = {
        "sub": "user-123",
        "iss": _VALID_ISSUER,
        "token_use": "access",
        "client_id": settings.cognito_client_id,
        "iat": now,
        "exp": now + 300,
    }
    claims.update(overrides)
    return jwt.encode(claims, _PRIVATE_KEY, algorithm="RS256")


def test_valid_access_token_returns_its_sub() -> None:
    """The fallback header, used by local dev and anything not behind CloudFront."""
    assert auth.get_current_sub(authorization=f"Bearer {_token()}") == "user-123"


def test_valid_access_token_in_the_codeignite_header_returns_its_sub() -> None:
    """The header the deployed frontend actually sends.

    CloudFront's OAC overwrites `Authorization` with its own SigV4 signature
    (see auth.py's module docstring), so this is the only header a hosted
    request can carry a Cognito token in.
    """
    assert auth.get_current_sub(x_codeignite_authorization=f"Bearer {_token()}") == "user-123"


def test_codeignite_header_wins_over_an_oac_signature_in_authorization() -> None:
    """Reproduces the hosted request shape exactly: a real token in the custom
    header, CloudFront's SigV4 signature in `Authorization`. Preferring
    `Authorization` here would 401 a correctly-authenticated user.
    """
    assert (
        auth.get_current_sub(
            x_codeignite_authorization=f"Bearer {_token()}",
            authorization="AWS4-HMAC-SHA256 Credential=AKIA/20260809/us-east-1/lambda/aws4_request",
        )
        == "user-123"
    )


def test_missing_header_is_rejected() -> None:
    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(authorization=None)
    assert exc_info.value.status_code == 401


def test_oac_signature_alone_is_rejected() -> None:
    """No custom header at all — what every request looked like before the fix."""
    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(
            authorization="AWS4-HMAC-SHA256 Credential=AKIA/20260809/us-east-1/lambda/aws4_request"
        )
    assert exc_info.value.status_code == 401


def test_non_bearer_scheme_is_rejected() -> None:
    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(authorization=f"Basic {_token()}")
    assert exc_info.value.status_code == 401


def test_garbage_token_is_rejected() -> None:
    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(authorization="Bearer not-a-jwt")
    assert exc_info.value.status_code == 401


def test_expired_token_is_rejected() -> None:
    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(authorization=f"Bearer {_token(exp=int(time.time()) - 10)}")
    assert exc_info.value.status_code == 401


def test_token_from_a_different_pool_is_rejected() -> None:
    other_issuer = (
        f"https://cognito-idp.{settings.aws_region}.amazonaws.com/us-east-1_someOtherPool"
    )
    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(authorization=f"Bearer {_token(iss=other_issuer)}")
    assert exc_info.value.status_code == 401


def test_id_token_in_place_of_access_token_is_rejected() -> None:
    # Cognito ID tokens carry token_use="id" — this is exactly the mixup the
    # stage-3 plan calls out: "verify the access token, not the ID token."
    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(authorization=f"Bearer {_token(token_use='id')}")
    assert exc_info.value.status_code == 401


def test_token_for_a_different_app_client_is_rejected() -> None:
    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(authorization=f"Bearer {_token(client_id='some-other-client-id')}")
    assert exc_info.value.status_code == 401


def test_token_without_a_sub_claim_is_rejected() -> None:
    # `require: ["exp", "iss", "sub"]` in auth.py's decode call means PyJWT
    # itself raises before this is ever reached — asserted here as the
    # observable behaviour, not the mechanism.
    now = int(time.time())
    claims = {
        "iss": _VALID_ISSUER,
        "token_use": "access",
        "client_id": settings.cognito_client_id,
        "iat": now,
        "exp": now + 300,
    }
    token = jwt.encode(claims, _PRIVATE_KEY, algorithm="RS256")

    with pytest.raises(HTTPException) as exc_info:
        auth.get_current_sub(authorization=f"Bearer {token}")
    assert exc_info.value.status_code == 401
