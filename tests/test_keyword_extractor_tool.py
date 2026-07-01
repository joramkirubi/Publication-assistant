from src.tools.keyword_extractor_tool import keyword_extractor

TEXT = """
This project implements a multi-agent system using LangGraph for orchestration.
It integrates retrieval-augmented generation (RAG) with a vector database and
exposes tools for agents to call. Built with LangChain and a Groq-hosted LLM.
"""


def test_domain_terms_are_boosted_to_top():
    result = keyword_extractor.invoke({"text": TEXT, "top_n": 10})
    keywords = result["keywords"]
    # domain terms should rank ahead of generic words due to the boost
    assert "langgraph" in keywords
    assert "rag" in keywords or "vector" in keywords


def test_stopwords_are_excluded():
    result = keyword_extractor.invoke({"text": TEXT, "top_n": 20})
    assert "with" not in result["keywords"]
    assert "this" not in result["keywords"]


def test_suggested_tags_are_nonempty_for_nonempty_text():
    result = keyword_extractor.invoke({"text": TEXT, "top_n": 10})
    assert len(result["suggested_tags"]) > 0
