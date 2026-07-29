from unittest.mock import MagicMock, patch

from src.tools.web_search_tool import web_search


class TestWebSearch:
    @patch("src.tools.web_search_tool.settings")
    def test_returns_empty_note_when_no_api_key(self, mock_settings):
        mock_settings.tavily_api_key = ""
        result = web_search.invoke({"query": "LangGraph multi-agent", "max_results": 5})
        assert result["results"] == []
        assert "TAVILY_API_KEY not set" in result["note"]

    @patch("src.tools.web_search_tool.settings")
    def test_parses_and_truncates_results(self, mock_settings):
        mock_settings.tavily_api_key = "tvly-fake"

        mock_client = MagicMock()
        mock_client.search.return_value = {
            "results": [
                {"title": "Project A", "url": "https://a.example", "content": "x" * 500},
                {"title": "Project B", "url": "https://b.example", "content": "short"},
            ]
        }

        with patch("tavily.TavilyClient", return_value=mock_client):
            result = web_search.invoke({"query": "test query", "max_results": 2})

        assert len(result["results"]) == 2
        assert result["results"][0]["title"] == "Project A"
        assert len(result["results"][0]["snippet"]) == 300
        assert result["results"][1]["snippet"] == "short"
        assert result["note"] == ""

    @patch("src.tools.web_search_tool.settings")
    def test_handles_missing_tavily_package_gracefully(self, mock_settings):
        mock_settings.tavily_api_key = "tvly-fake"
        with patch.dict("sys.modules", {"tavily": None}):
            result = web_search.invoke({"query": "test query"})
        assert result["results"] == []
        assert "tavily-python not installed" in result["note"]