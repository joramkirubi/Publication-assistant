"""
Agent: Content Improver

Role: proposes a better title and summary for the project. Uses the web
search tool to gather a little positioning context (how similar projects
are titled/described), then asks the LLM to draft improved copy grounded
in the actual README content (to avoid hallucinated claims).
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.llm import get_llm
from src.state import PublicationAssistantState
from src.tools.web_search_tool import web_search

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are an editorial specialist for Ready Tensor publications. \
Given a project's README and some web context about similarly positioned projects, \
propose:

1. A specific, discoverable title (avoid vague titles like "My Project")
2. A 2-3 sentence summary that clearly states what the project does and why it matters
3. One sentence of positioning notes: how this project compares to similar ones you saw

Ground every claim in the README content provided â€” do not invent features, \
performance numbers, or capabilities that aren't described in the README.

Respond in exactly this format:
TITLE: <title>
SUMMARY: <summary>
POSITIONING: <positioning notes>"""


def content_improver_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")
    repo_name = state.get("repo", "")

    if not readme_text:
        return {
            "suggested_title": "",
            "suggested_summary": "",
            "positioning_notes": "",
            "errors": ["ContentImprover: skipped, no README text available."],
        }

    search_query = f"{repo_name} AI ML GitHub project similar tools"
    search_result = web_search.invoke({"query": search_query, "max_results": 5})
    context_snippets = "\n".join(
        f"- {r['title']}: {r['snippet']}" for r in search_result.get("results", [])
    ) or "(no web context available)"

    new_errors = []
    try:
        llm = get_llm(temperature=0.4)
        messages = [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(
                content=(
                    f"README:\n{readme_text[:4000]}\n\n"
                    f"Similar projects found via web search:\n{context_snippets}"
                )
            ),
        ]
        response = llm.invoke(messages)
        text = response.content

        title = _extract_field(text, "TITLE")
        summary = _extract_field(text, "SUMMARY")
        positioning = _extract_field(text, "POSITIONING")
    except Exception as exc:  # noqa: BLE001
        logger.exception("content_improver_node LLM call failed")
        new_errors.append(f"ContentImprover: LLM drafting failed ({exc}).")
        title, summary, positioning = "", "", ""

    return {
        "suggested_title": title,
        "suggested_summary": summary,
        "positioning_notes": positioning,
        "errors": new_errors,
    }


def _extract_field(text: str, field: str) -> str:
    for line in text.splitlines():
        if line.strip().upper().startswith(field.upper() + ":"):
            return line.split(":", 1)[1].strip()
    return ""