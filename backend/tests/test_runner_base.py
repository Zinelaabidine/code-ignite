"""Nothing implements `Runner` yet — this only pins down the contract that
`LocalDockerRunner` (next PR) and `KubernetesJobRunner` (later) both have to
satisfy, so a signature change is caught here rather than in a caller."""

from codeignite.runner.base import Runner, RunResult


class FakeRunner:
    """Minimal conforming implementation, used only to exercise the Protocol."""

    def run(self, code: str, language: str, timeout: int) -> RunResult:
        return RunResult(
            stdout="hi\n",
            stderr="",
            exit_code=0,
            duration_ms=1,
            status="ok",
        )


def test_fake_runner_satisfies_the_protocol() -> None:
    runner: Runner = FakeRunner()
    assert isinstance(runner, Runner)


def test_run_result_defaults_to_not_truncated() -> None:
    result = RunResult(stdout="", stderr="", exit_code=0, duration_ms=0, status="ok")
    assert result.truncated is False


def test_run_result_is_frozen() -> None:
    result = RunResult(stdout="", stderr="", exit_code=0, duration_ms=0, status="ok")
    try:
        result.status = "error"  # type: ignore[misc]
    except AttributeError:
        pass
    else:
        raise AssertionError("RunResult instances must be immutable")
