FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:0.13 /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY libreglance ./libreglance

ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1

# The registration API by default; the private poll service overrides it with `libreglance.poll_api:app`.
CMD ["uvicorn", "libreglance.api:app", "--host", "0.0.0.0", "--port", "8080"]
