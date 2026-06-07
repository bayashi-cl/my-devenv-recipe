FROM docker.io/library/debian:trixie AS builder

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_COMPILE_BYTECODE=1 

# Install external dependencies first to leverage layer cache
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --package mdr-server --frozen --no-dev --no-install-workspace

# Install workspace packages
COPY packages/ packages/
RUN uv sync --package mdr-server --frozen --no-dev --no-editable


FROM docker.io/library/debian:trixie-slim

WORKDIR /app

COPY --from=builder /opt/python /opt/python
COPY --from=builder /app/.venv /app/.venv

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000

CMD ["python", "-m", "http.server", "8000"]
