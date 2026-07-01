"""
Tool: KeywordExtractorTool

Extracts candidate keywords/tags from text using simple, dependency-light
term-frequency scoring with a stopword filter and a bias toward AI/ML
domain terms. This is deterministic and doesn't require another LLM call,
which keeps the Metadata Recommender agent fast and cheap.
"""
import re
from collections import Counter

from langchain_core.tools import tool

STOPWORDS = {
    "the", "a", "an", "and", "or", "but", "if", "then", "is", "are", "was",
    "were", "be", "been", "being", "to", "of", "in", "on", "for", "with",
    "this", "that", "it", "as", "by", "at", "from", "your", "you", "we",
    "our", "can", "will", "using", "use", "used", "not", "no", "all", "also",
    "here", "there", "which", "these", "those", "into", "such", "have",
    "has", "had", "do", "does", "did", "so", "than", "their", "its", "it's",
}

# Known AI/ML domain terms get a score boost when found, since these make
# better Ready Tensor tags than generic English words.
DOMAIN_BOOST_TERMS = {
    "langgraph", "langchain", "crewai", "autogen", "rag", "llm", "agent",
    "agents", "orchestration", "embedding", "embeddings", "vector",
    "transformer", "fine-tuning", "finetuning", "pytorch", "tensorflow",
    "classification", "regression", "nlp", "cv", "reinforcement",
    "multi-agent", "mcp", "tool-use", "retrieval", "inference", "dataset",
    "benchmark", "evaluation", "openai", "anthropic", "huggingface",
}

WORD_RE = re.compile(r"[a-zA-Z][a-zA-Z0-9\-]{2,}")


@tool("keyword_extractor")
def keyword_extractor(text: str, top_n: int = 10) -> dict:
    """
    Extract candidate keywords/tags from README or project description text.

    Args:
        text: The text to analyze (e.g. README content).
        top_n: Number of top keywords to return (default 10).

    Returns:
        A dict with 'keywords' (ranked list) and 'suggested_tags'
        (a cleaned-up subset formatted for publication tagging).
    """
    words = [w.lower() for w in WORD_RE.findall(text)]
    filtered = [w for w in words if w not in STOPWORDS and len(w) > 2]

    counts = Counter(filtered)
    for term in list(counts.keys()):
        if term in DOMAIN_BOOST_TERMS:
            counts[term] *= 3  # boost domain-relevant terms

    ranked = [word for word, _ in counts.most_common(top_n)]
    suggested_tags = [w.replace("-", " ").title().replace(" ", "") for w in ranked[:8]]

    return {"keywords": ranked, "suggested_tags": suggested_tags}
