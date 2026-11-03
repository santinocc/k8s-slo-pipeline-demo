# Ingestion job image for the k8s-slo-pipeline-demo learning project.
# Same pinned base image as the API.
ARG PYTHON_IMAGE=python:3.12.13-slim@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36

FROM ${PYTHON_IMAGE} AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN pip --python /opt/venv/bin/python install -r /tmp/requirements.txt

FROM ${PYTHON_IMAGE}
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
COPY --from=builder /opt/venv /opt/venv
WORKDIR /srv
COPY ingest.py ./
USER 10001:10001
CMD ["python", "ingest.py"]
