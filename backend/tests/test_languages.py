"""The registry is data, but it's data other modules trust without
re-validating — a bad entry here would surface as a confusing Docker failure
three layers away instead of a failing test right here."""

from codeignite.domain.languages import LANGUAGES, Language


def test_python_is_registered() -> None:
    assert "python" in LANGUAGES


def test_every_entry_has_a_non_empty_image_command_and_extension() -> None:
    for name, language in LANGUAGES.items():
        assert isinstance(language, Language)
        assert language.image, f"{name}: image must not be empty"
        assert language.command, f"{name}: command must not be empty"
        assert all(isinstance(part, str) for part in language.command), (
            f"{name}: command must be a list of strings — never a shell string"
        )
        assert language.extension, f"{name}: extension must not be empty"
        assert not language.extension.startswith("."), (
            f"{name}: extension should be bare (e.g. 'py'), not '.py'"
        )


def test_language_is_frozen() -> None:
    python = LANGUAGES["python"]
    try:
        python.image = "something-else"  # type: ignore[misc]
    except AttributeError:
        pass
    else:
        raise AssertionError("Language instances must be immutable")
