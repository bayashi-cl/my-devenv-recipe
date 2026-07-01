FROM debian:trixie AS builder

WORKDIR /app
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

ENV UV_PYTHON_INSTALL_DIR=/opt/python

COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-dev --no-install-workspace --no-editable --package mdr_api

COPY python/ ./python/
RUN uv sync --frozen --no-dev --no-editable --package mdr_api

FROM debian:trixie
WORKDIR /app

COPY --from=builder /opt/python/ /opt/python/
COPY --from=builder /app/.venv/ /app/.venv/

ENV PATH="/app/.venv/bin:$PATH"
EXPOSE 8000

CMD ["uvicorn", "mdr_api:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]
