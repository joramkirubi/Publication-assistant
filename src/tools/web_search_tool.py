"""
Tool: WebSearchTool

Thin wrapper around Tavily's search API, used by the Content Improver agent
to see how similar projects are titled/described in the wild before it
proposes a new title or summary. Degrades gracefully (returns an empty
result with an explanation) if no TAVILY_API_KEY is configured, so the rest
of the pipeline can still run without it.
"""
from langchain_core.tools import tool

from src.config import settings


@tool("web_search")
def web_search(query: str, max_results: int = 5) -> dict:
    """
    Search the web for context on similar AI/ML projects, naming
    conventions, or terminology relevant to a query.

    Args:
        query: Search query, e.g. "LangGraph multi-agent GitHub repo README".
        max_results: Max number of results to return (default 5).

    Returns:
        A dict with 'results': a list of {title, url, snippet} dicts.
        If no Tavily API key is configured, returns an empty list with a note.
    """
    if not settings.tavily_api_key:
        return {
            "results": [],
            "note": (
                "TAVILY_API_KEY not set — web search skipped. "
                "Set it in .env to enable competitive/positioning research."
            ),
        }

    try:
        from tavily import TavilyClient
    except ImportError as exc:
        return {"results": [], "note": f"tavily-python not installed: {exc}"}

    client = TavilyClient(api_key=settings.tavily_api_key)
    response = client.search(query=query, max_results=max_results)

    results = [
        {
            "title": item.get("title", ""),
            "url": item.get("url", ""),
            "snippet": item.get("content", "")[:300],
        }
        for item in response.get("results", [])
    ]
    return {"results": results, "note": ""}
