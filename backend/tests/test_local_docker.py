"""Two tiers of test here, deliberately kept in one file so the split is
visible: functions with no `docker` marker exercise pure logic (argv
construction, exit-code classification, output capping) and run everywhere,
including CI. The `@pytest.mark.docker` class actually launches containers
and needs a real Docker daemon — deselected by default via
`pytest -m "not docker"`; run the full stage 1 checklist in
docs/code-playground-implementation-plan.md with
`pytest -m docker tests/test_local_docker.py` on a machine that has Docker.
"""

from pathlib import Path

import pytest

from codeignite.domain.languages import LANGUAGES
from codeignite.runner.local_docker import (
    MAX_OUTPUT_BYTES,
    LocalDockerRunner,
    UnknownLanguageError,
    _build_argv,
    _classify,
    _decode_capped,
)


def test_run_rejects_a_language_outside_the_registry() -> None:
    # The API validates this earlier (see test_routes_runs.py) — this pins
    # down the runner's own defence for any other caller.
    with pytest.raises(UnknownLanguageError):
        LocalDockerRunner().run(code="1", language="cobol", timeout=5)


class TestBuildArgv:
    """One assertion per flag from docs/code-playground-plan.md's flag
    table — a flag silently dropped here is a sandbox with a hole in it."""

    def test_argv_is_a_flat_list_of_strings(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert all(isinstance(part, str) for part in argv)

    def test_network_is_disabled(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert argv[argv.index("--network") + 1] == "none"

    def test_memory_and_swap_are_both_capped(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert argv[argv.index("--memory") + 1] == "256m"
        assert argv[argv.index("--memory-swap") + 1] == "256m"

    def test_root_filesystem_is_read_only(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert "--read-only" in argv
        assert argv[argv.index("--tmpfs") + 1] == "/tmp:size=16m"

    def test_runs_as_the_nobody_uid(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert argv[argv.index("--user") + 1] == "65534"

    def test_capabilities_and_privilege_escalation_are_dropped(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert argv[argv.index("--cap-drop") + 1] == "ALL"
        assert "no-new-privileges" in argv

    def test_pids_are_limited(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert argv[argv.index("--pids-limit") + 1] == "64"

    def test_workspace_is_mounted_read_only_at_sandbox(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert argv[argv.index("-v") + 1] == f"{tmp_path}:/sandbox:ro"

    def test_container_is_named_for_force_kill(self, tmp_path: Path) -> None:
        argv = _build_argv(tmp_path, LANGUAGES["python"], "job-test", 8)
        assert argv[argv.index("--name") + 1] == "job-test"

    def test_inner_timeout_wraps_the_language_command(self, tmp_path: Path) -> None:
        spec = LANGUAGES["python"]
        argv = _build_argv(tmp_path, spec, "job-test", 8)
        assert argv[-len(spec.command) - 2 :] == ["timeout", "8", *spec.command]


class TestClassify:
    def test_124_is_timeout(self) -> None:
        assert _classify(124) == ("timeout", 124)

    def test_137_is_oom(self) -> None:
        assert _classify(137) == ("oom", 137)

    def test_0_is_ok(self) -> None:
        assert _classify(0) == ("ok", 0)

    def test_other_nonzero_codes_are_error_and_keep_the_real_code(self) -> None:
        assert _classify(1) == ("error", 1)
        assert _classify(255) == ("error", 255)


class TestDecodeCapped:
    def test_short_output_passes_through_unchanged(self) -> None:
        text, truncated = _decode_capped(b"hi\n")
        assert text == "hi\n"
        assert truncated is False

    def test_output_over_the_cap_is_truncated_and_flagged(self) -> None:
        raw = b"x" * (MAX_OUTPUT_BYTES + 100)
        text, truncated = _decode_capped(raw)
        assert len(text.encode()) == MAX_OUTPUT_BYTES
        assert truncated is True

    def test_invalid_utf8_does_not_raise(self) -> None:
        text, _truncated = _decode_capped(b"\xff\xfe")
        assert isinstance(text, str)


@pytest.mark.docker
class TestLocalDockerRunnerLive:
    """Requires a Docker daemon. This is the stage 1 "Definition of done"
    checklist from docs/code-playground-implementation-plan.md, encoded as
    tests rather than left as manual steps."""

    def test_hello_world(self) -> None:
        result = LocalDockerRunner().run(code="print('hi')", language="python", timeout=8)
        assert result.status == "ok"
        assert result.stdout == "hi\n"
        assert result.exit_code == 0

    def test_an_infinite_loop_times_out_within_the_limit(self) -> None:
        result = LocalDockerRunner().run(
            code="while True:\n    pass\n", language="python", timeout=3
        )
        assert result.status == "timeout"

    def test_a_large_allocation_is_oom_killed(self) -> None:
        code = "x = bytearray(512 * 1024 * 1024)\n"
        result = LocalDockerRunner().run(code=code, language="python", timeout=8)
        assert result.status == "oom"

    def test_network_access_is_actually_blocked(self) -> None:
        code = (
            "import socket\n"
            "s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n"
            "s.settimeout(2)\n"
            "try:\n"
            "    s.connect(('1.1.1.1', 80))\n"
            "    print('reached')\n"
            "except OSError:\n"
            "    print('blocked')\n"
        )
        result = LocalDockerRunner().run(code=code, language="python", timeout=8)
        assert result.stdout.strip() == "blocked"

    def test_root_filesystem_is_actually_read_only(self) -> None:
        code = (
            "try:\n"
            "    open('/etc/testfile', 'w').write('x')\n"
            "    print('wrote')\n"
            "except OSError:\n"
            "    print('blocked')\n"
        )
        result = LocalDockerRunner().run(code=code, language="python", timeout=8)
        assert result.stdout.strip() == "blocked"
