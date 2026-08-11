from unittest.mock import MagicMock, patch

import pytest
import requests

from src.tools.github_repo_tool import (
    _fetch_readme,
    _fetch_repo_metadata,
    _fetch_top_level_structure,
    _parse_owner_repo,
    github_repo_reader,
)


class TestParseOwnerRepo:
    def test_parses_plain_url(self):
        assert _parse_owner_repo("https://github.com/owner/repo") == ("owner", "repo")

    def test_parses_url_with_dot_git(self):
        assert _parse_owner_repo("https://github.com/owner/repo.git") == ("owner", "repo")

    def test_raises_on_unparseable_url(self):
        with pytest.raises(ValueError):
            _parse_owner_repo("not-a-github-url")


class TestFetchReadme:
    @patch("src.tools.github_repo_tool.requests.get")
    def test_returns_placeholder_on_404(self, mock_get):
        mock_get.return_value = MagicMock(status_code=404)
        result = _fetch_readme("owner", "repo")
        assert "No README found" in result

    @patch("src.tools.github_repo_tool.requests.get")
    def test_decodes_base64_content(self, mock_get):
        import base64

        encoded = base64.b64encode(b"# Hello World").decode()
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {"content": encoded}
        mock_resp.raise_for_status.return_value = None
        mock_get.return_value = mock_resp
        assert _fetch_readme("owner", "repo") == "# Hello World"

    @patch("src.resilience.time.sleep", return_value=None)
    @patch("src.tools.github_repo_tool.requests.get")
    def test_retries_on_connection_error_then_succeeds(self, mock_get, mock_sleep):
        import base64

        encoded = base64.b64encode(b"# Retried").decode()
        success_resp = MagicMock(status_code=200)
        success_resp.json.return_value = {"content": encoded}
        success_resp.raise_for_status.return_value = None

        mock_get.side_effect = [
            requests.ConnectionError("blip"),
            success_resp,
        ]
        assert _fetch_readme("owner", "repo") == "# Retried"
        assert mock_get.call_count == 2

    @patch("src.resilience.time.sleep", return_value=None)
    @patch("src.tools.github_repo_tool.requests.get")
    def test_gives_up_after_max_retries(self, mock_get, mock_sleep):
        mock_get.side_effect = requests.ConnectionError("still down")
        # Explicit try/except here (rather than pytest.raises) so the
        # exception's own message and type are inspected directly --
        # verifying not just that *something* was raised, but that it's
        # the original ConnectionError re-raised unmodified after
        # exhausting retries, not wrapped or swallowed along the way.
        try:
            _fetch_readme("owner", "repo")
            pytest.fail("expected requests.ConnectionError to propagate after max retries")
        except requests.ConnectionError as exc:
            assert "still down" in str(exc)
        assert mock_get.call_count == 3  # max_attempts=3 from _github_retry


class TestFetchTopLevelStructure:
    @patch("src.tools.github_repo_tool.requests.get")
    def test_sorts_and_marks_directories(self, mock_get):
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = [
            {"name": "src", "type": "dir"},
            {"name": "README.md", "type": "file"},
        ]
        mock_resp.raise_for_status.return_value = None
        mock_get.return_value = mock_resp
        result = _fetch_top_level_structure("owner", "repo")
        assert result == ["README.md", "src/"]


class TestFetchRepoMetadata:
    @patch("src.tools.github_repo_tool.requests.get")
    def test_extracts_expected_fields(self, mock_get):
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {
            "description": "A test repo",
            "stargazers_count": 42,
            "language": "Python",
            "topics": ["ai", "agents"],
            "license": {"name": "MIT"},
            "open_issues_count": 3,
        }
        mock_resp.raise_for_status.return_value = None
        mock_get.return_value = mock_resp
        result = _fetch_repo_metadata("owner", "repo")
        assert result == {
            "description": "A test repo",
            "stars": 42,
            "language": "Python",
            "topics": ["ai", "agents"],
            "license": "MIT",
            "open_issues": 3,
        }


class TestGithubRepoReader:
    @patch("src.tools.github_repo_tool._fetch_repo_metadata")
    @patch("src.tools.github_repo_tool._fetch_top_level_structure")
    @patch("src.tools.github_repo_tool._fetch_readme")
    def test_assembles_full_result(self, mock_readme, mock_structure, mock_metadata):
        mock_readme.return_value = "# Title"
        mock_structure.return_value = ["README.md"]
        mock_metadata.return_value = {"stars": 1}

        result = github_repo_reader.invoke({"repo_url": "https://github.com/owner/repo"})
        assert result["owner"] == "owner"
        assert result["repo"] == "repo"
        assert result["readme"] == "# Title"
        assert result["file_structure"] == ["README.md"]
        assert result["metadata"] == {"stars": 1}