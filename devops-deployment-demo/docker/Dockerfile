# ---- Build a small, production-ish image ----
FROM python:3.12-slim

# Don't buffer stdout/stderr (better logs), don't write .pyc files
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DEPLOY_MODE=Docker \
    APP_VERSION=1.0.0 \
    GREETING="Hello from inside a Docker container!" \
    PORT=8080

WORKDIR /app

# Install deps first (better layer caching: deps change less often than code)
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code
COPY app/ .

# Run as a non-root user for safety
RUN useradd --system --no-create-home appuser && chown -R appuser /app
USER appuser

EXPOSE 8080

# Container-level health check (docker ps shows healthy/unhealthy)
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8080/healthz').status==200 else 1)"

CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:8080", "app:app"]
