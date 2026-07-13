"""
Agent: Metadata Recommender

ROLE: Tagging/categorization specialist — one of two parallel branches
that run right after Repo Analyzer.
SPECIALIZATION: Combines a deterministic keyword-extraction tool with a
narrow LLM pass whose only job is filtering raw candidates down to
publication-quality tags. Does not touch title, summary, or structure
checking — those belong to other agents.
READS FROM STATE: readme_text
WRITES TO STATE: suggested_keywords, suggested_tags, errors
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.llm import get_llm
from src.state import PublicationAssistantState
from src.tools.keyword_extractor_tool import keyword_extractor

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are a metadata specialist for Ready Tensor, a platform for AI/ML \
publications. You are given a raw list of candidate keywords extracted from a \
project's README, plus the README text itself. Your job is to select and refine \
the best 5-8 tags for this project's publication listing.

Good tags are specific (e.g. "LangGraph", "RAG", "MultiAgentSystems"), not generic \
English words. Prefer CamelCase or hyphenated multi-word tags where natural, \
consistent with how Ready Tensor publications are tagged.

Respond with ONLY a comma-separated list of tags, nothing else."""


def metadata_recommender_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")

    if not readme_text:
        return {
            "suggested_keywords": [],
            "suggested_tags": [],
            "errors": ["MetadataRecommender: skipped, no README text available."],
        }

    raw = keyword_extractor.invoke({"text": readme_text, "top_n": 15})
    candidate_keywords = raw["keywords"]
    new_errors = []

    try:
        llm = get_llm(temperature=0.2)
        messages = [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(
                content=(
                    f"Candidate keywords: {', '.join(candidate_keywords)}\n\n"
                    f"README excerpt:\n{readme_text[:3000]}"
                )
            ),
        ]
        response = llm.invoke(messages)
        tags = [t.strip() for t in response.content.split(",") if t.strip()]
    except Exception as exc:  # noqa: BLE001
        logger.exception("metadata_recommender_node LLM call failed")
        new_errors.append(f"MetadataRecommender: LLM refinement failed ({exc}), using raw tags.")
        tags = raw["suggested_tags"]

    return {
        "suggested_keywords": candidate_keywords,
        "suggested_tags": tags,
        "errors": new_errors,
    }
