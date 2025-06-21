FROM selenium/standalone-chrome:124.0

# ── switch to root so we can apt-install ───────────────────────────
USER root

RUN apt-get update \
 && apt-get install -y python3-pip \
 && rm -rf /var/lib/apt/lists/*

# ── application layer ──────────────────────────────────────────────
WORKDIR /svc
RUN pip3 install --no-cache-dir fastapi uvicorn
COPY service.py .

# drop back to the non-root selenium user (UID 1200 == seluser)
USER 1200

CMD ["uvicorn", "service:app", "--host", "0.0.0.0", "--port", "9003"]