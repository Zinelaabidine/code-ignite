"""Entrypoint: `python -m codeignite.worker`.

Structured logging, one line per event, `job_id` attached via `extra=` on
every log call in `loop.py` — deliberately never the user's code or the
job's stdout/stderr, which are untrusted input and don't belong in logs.
"""

import logging

from codeignite.config import settings
from codeignite.worker.loop import run_forever


def main() -> None:
    logging.basicConfig(
        level=settings.log_level,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    run_forever()


if __name__ == "__main__":
    main()
