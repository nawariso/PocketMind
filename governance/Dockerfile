# POC base only. Organizational rollout must use an approved digest-pinned image.
ARG PYTHON_IMAGE=python:3.11-slim
FROM ${PYTHON_IMAGE}
RUN useradd --uid 10001 --create-home governance && mkdir /state && chown 10001:10001 /state
WORKDIR /app
COPY governance /app/governance
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10001:10001
CMD ["python", "-m", "governance", "serve", "--fixture", "--embedded-agent", "--host", "0.0.0.0", "--state", "/state"]
