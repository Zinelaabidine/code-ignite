"""The `jobs/{job_id}/input.json` shape — the second half of the storage
layout fixed in `docs/code-playground-plan.md`'s "flow" section. The other
half, `result.json`, reuses `codeignite.runner.base.RunResult` field-for-field
rather than a second model, since a run's result is a run's result whether it
came straight from the runner or via S3.

`user_sub` exists now, ahead of stage 3's Cognito verification landing, so
this shape doesn't change again when auth arrives — it's simply unset
(`None`) until `api/routes_runs.py` has a verified `sub` to put in it.
"""

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class JobInput:
    code: str
    language: str
    # ISO 8601, set once at submission — not reparsed or validated on the way
    # back out; it's diagnostic metadata, not something the worker acts on.
    submitted_at: str
    user_sub: str | None = None
