"""
Central configuration for the Publication Assistant.

All secrets are read from environment variables (see .env.example).
Nothing here should ever contain a real API key.
"""
import os
from dataclasses import dataclass

from dotenv import load_dotenv

load_dotenv()


@dataclass(frozen=True)
class Settings:
    groq_api_key: str = os.getenv("GROQ_API_KEY", "")
    github_token: str = os.getenv("GITHUB_TOKEN", "")  # optional, raises rate limit
    tavily_api_key: str = os.getenv("TAVILY_API_KEY", "")

    model_name: str = os.getenv("MODEL_NAME", "llama-3.3-70b-versatile")
    model_temperature: float = float(os.getenv("MODEL_TEMPERATURE", "0.3"))

    max_readme_chars: int = 12_000  # truncate huge READMEs before sending to the LLM
    request_timeout: int = 15  # seconds, for outbound HTTP calls


settings = Settings()


def require_groq_key() -> None:
    if not settings.groq_api_key:
        raise EnvironmentError(
            "GROQ_API_KEY is not set. Copy .env.example to .env and fill it in."
        )

