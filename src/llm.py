"""
Single place that constructs the LLM client, so every agent uses the same
model/temperature configuration.
"""
from langchain_groq import ChatGroq

from src.config import require_groq_key, settings


def get_llm(temperature: float | None = None) -> ChatGroq:
    require_groq_key()
    return ChatGroq(
        model=settings.model_name,
        temperature=temperature if temperature is not None else settings.model_temperature,
        api_key=settings.groq_api_key,
        timeout=60,
        max_retries=2,
    )
