# Publication Assistant - container image
#
# Builds an image that runs the Streamlit UI by default. The CLI is also
# available inside the same image (see docker-compose.yml for a CLI
# service definition), since both entry points share the same
# dependencies and source tree.
FROM python:3.11-slim

WORKDIR /app

# Install dependencies first so this layer is cached across rebuilds
# that only change application code, not requirements.txt.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Secrets (GROQ_API_KEY, TAVILY_API_KEY, GITHUB_TOKEN) are intentionally
# NOT baked into the image. Pass them at run time:
#   docker run -e GROQ_API_KEY=... -p 8501:8501 publication-assistant
RUN mkdir -p reports

EXPOSE 8501

# Container-level health check, backed by the same logic as
# `python main.py --health-check` -- distinct from Streamlit's own
# liveness endpoint, which only confirms the process is up, not that
# GROQ_API_KEY/GitHub connectivity are actually configured correctly.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python main.py --health-check || exit 1

CMD ["streamlit", "run", "app.py", "--server.address=0.0.0.0", "--server.port=8501"]