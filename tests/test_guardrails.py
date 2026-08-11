import pytest

from src.guardrails import (
    GuardrailViolation,
    MAX_DESCRIPTION_LENGTH,
    filter_output,
    sanitize_user_description,
    validate_repo_url,
)


class TestValidateRepoUrl:
    def test_accepts_plain_https_url(self):
        assert validate_repo_url("https://github.com/owner/repo") == "https://github.com/owner/repo"

    def test_strips_trailing_slash(self):
        assert validate_repo_url("https://github.com/owner/repo/") == "https://github.com/owner/repo"

    def test_strips_dot_git_suffix(self):
        assert validate_repo_url("https://github.com/owner/repo.git") == "https://github.com/owner/repo"

    def test_strips_surrounding_whitespace(self):
        assert validate_repo_url("  https://github.com/owner/repo  ") == "https://github.com/owner/repo"

    @pytest.mark.parametrize(
        "bad_url",
        [
            "",
            "   ",
            "not-a-url",
            "http://github.com/owner/repo",  # http, not https
            "https://gitlab.com/owner/repo",  # wrong host
            "https://github.com/owner",  # missing repo segment
            "https://github.com/owner/repo/extra/path",  # extra path segments
            "javascript:alert(1)",
            "ftp://github.com/owner/repo",
            "https://github.com.evil.com/owner/repo",  # lookalike host
        ],
    )
    def test_rejects_invalid_urls(self, bad_url):
        with pytest.raises(GuardrailViolation):
            validate_repo_url(bad_url)

    def test_rejects_non_string_input(self):
        with pytest.raises(GuardrailViolation):
            validate_repo_url(None)  # type: ignore[arg-type]

    def test_rejects_overly_long_url(self):
        with pytest.raises(GuardrailViolation):
            validate_repo_url("https://github.com/owner/" + "a" * 300)

    def test_rejects_control_characters(self):
        with pytest.raises(GuardrailViolation):
            validate_repo_url("https://github.com/owner/repo\x00")


class TestSanitizeUserDescription:
    def test_none_returns_empty_string(self):
        assert sanitize_user_description(None) == ""

    def test_empty_string_returns_empty_string(self):
        assert sanitize_user_description("") == ""

    def test_passes_through_normal_text(self):
        assert sanitize_user_description("A RAG pipeline for medical Q&A") == (
            "A RAG pipeline for medical Q&A"
        )

    def test_truncates_to_max_length(self):
        long_text = "x" * (MAX_DESCRIPTION_LENGTH + 100)
        result = sanitize_user_description(long_text)
        assert len(result) == MAX_DESCRIPTION_LENGTH

    def test_collapses_excess_whitespace(self):
        assert sanitize_user_description("hello    \n\n  world") == "hello world"

    def test_strips_control_characters(self):
        assert sanitize_user_description("hello\x00world") == "helloworld"


class TestFilterOutput:
    def test_empty_text_passes_through(self):
        assert filter_output("") == ""

    def test_leaves_normal_text_unchanged(self):
        text = "## Summary\nThis project uses RAG and LangGraph."
        assert filter_output(text) == text

    def test_redacts_groq_key(self):
        text = "here is a key: gsk_" + "a" * 30
        result = filter_output(text)
        assert "gsk_" not in result
        assert "[REDACTED_GROQ_KEY]" in result

    def test_redacts_github_token(self):
        text = "token: ghp_" + "b" * 36
        result = filter_output(text)
        assert "ghp_" not in result
        assert "[REDACTED_GITHUB_TOKEN]" in result

    def test_redacts_tavily_key(self):
        text = "tvly-" + "c" * 32
        result = filter_output(text)
        assert "[REDACTED_TAVILY_KEY]" in result

    def test_redacts_multiple_secrets_in_same_text(self):
        text = f"a=gsk_{'x' * 25} b=ghp_{'y' * 36}"
        result = filter_output(text)
        assert "[REDACTED_GROQ_KEY]" in result
        assert "[REDACTED_GITHUB_TOKEN]" in result