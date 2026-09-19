# Slim AnnotationCrops gallery. Stdlib only — no nornir-buildmanager, imageregistration, CuPy, or torch.
FROM python:3.14-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    GALLERY_HOST=0.0.0.0 \
    GALLERY_PORT=8090 \
    GALLERY_VOLUME_DIR=/gallery-volumes \
    GALLERY_IDENTITY_MODE=stub

WORKDIR /app

COPY server.py identity.py catalog.py /app/
COPY static /app/static

RUN groupadd --gid 10001 gallery \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin gallery

EXPOSE 8090

USER 10001:10001

CMD ["python", "/app/server.py"]
