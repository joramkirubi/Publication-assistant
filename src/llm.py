"""
Single place that constructs the LLM client, so every agent uses the same
model/temperature configuration.
"""
from langchain_core.messages import BaseMessage
from langchain_groq import ChatGroq

from src.config import require_groq_key, settings
from src.resilience import with_retry, with_timeout


def get_llm(temperature: float | None = None) -> ChatGroq:
    require_groq_key()
    return ChatGroq(
        model=settings.model_name,
        temperature=temperature if temperature is not None else settings.model_temperature,
        api_key=settings.groq_api_key,
        timeout=60,
        max_retries=2,
    )


# App-level resilience on top of ChatGroq's own timeout/max_retries: those
# only cover the raw HTTP call, not e.g. the client raising before a
# request is even sent. This gives every agent the same
# retry-with-backoff + hard-timeout behavior via one call site instead of
# each agent re-implementing it.
@with_timeout(seconds=45)
@with_retry(max_attempts=2, base_delay=1.5, exceptions=(Exception,))
def _invoke(llm: ChatGroq, messages: list[BaseMessage]):
    return llm.invoke(messages)


def invoke_llm(llm: ChatGroq, messages: list[BaseMessage]):
    """
    Resilient wrapper around llm.invoke(): retries transient failures once
    with backoff, then enforces a hard 45s wall-clock timeout so a hung
    call can't stall the whole pipeline. Exceptions are re-raised for the
    caller's existing try/except-and-degrade logic to handle.
    """
    return _invoke(llm, messages)