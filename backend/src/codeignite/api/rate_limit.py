"""Per-user request throttling — stage 3 of
`docs/code-playground-implementation-plan.md`: "a simple in-process token
bucket keyed on `sub` (e.g. 10 runs/minute) with a `RateLimiter` interface.
Shared-state limiting lands with EKS; the interface is what matters now."

Only `submit_run` is metered (see `enforce_rate_limit`, used as
`POST /runs`'s dependency) — `GET /runs/{job_id}` is polled every 500 ms by
the frontend and metering it would break that.
"""

import time
from typing import Protocol

from fastapi import Depends, HTTPException

from codeignite.api.auth import get_current_sub

DEFAULT_CAPACITY = 10
DEFAULT_REFILL_PER_SECOND = DEFAULT_CAPACITY / 60  # 10 per minute


class RateLimiter(Protocol):
    def allow(self, key: str) -> bool: ...


class InProcessTokenBucketLimiter:
    """`capacity` tokens per `key`, refilled continuously at
    `refill_per_second`. Process-local — every API replica has its own
    bucket, which is the "shared-state limiting lands with EKS" tradeoff the
    plan calls out explicitly.
    """

    def __init__(
        self, capacity: int = DEFAULT_CAPACITY, refill_per_second: float = DEFAULT_REFILL_PER_SECOND
    ) -> None:
        self._capacity = capacity
        self._refill_per_second = refill_per_second
        self._tokens: dict[str, float] = {}
        self._last_check: dict[str, float] = {}

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        tokens = self._tokens.get(key, float(self._capacity))
        last_check = self._last_check.get(key, now)
        tokens = min(self._capacity, tokens + (now - last_check) * self._refill_per_second)

        allowed = tokens >= 1
        if allowed:
            tokens -= 1
        self._tokens[key] = tokens
        self._last_check[key] = now
        return allowed


_limiter: RateLimiter = InProcessTokenBucketLimiter()


def get_rate_limiter() -> RateLimiter:
    return _limiter


def enforce_rate_limit(
    sub: str = Depends(get_current_sub),
    limiter: RateLimiter = Depends(get_rate_limiter),
) -> str:
    """Verifies the token, then checks the bucket for that `sub`. Returns
    `sub` so a route needs only this one dependency to get both.
    """
    if not limiter.allow(sub):
        raise HTTPException(status_code=429, detail="Too many requests")
    return sub
