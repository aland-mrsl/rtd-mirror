FROM python:3.12-slim AS builder

RUN apt-get update && \
    apt-get install -y wget unzip git curl && \
    # Install Hugo extended binary
    HUGO_VER=0.140.2 && \
    curl -L "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VER}/hugo_extended_${HUGO_VER}_linux-amd64.tar.gz" \
      | tar xz -C /usr/local/bin hugo && \
    # Install Node (for Next.js builds)
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY projects.yaml .          # ← renamed from projects.txt
COPY scripts ./scripts

RUN python3 scripts/mirror.py
RUN python3 scripts/build-index.py

FROM nginx:alpine
COPY --from=builder /app/docs /usr/share/nginx/html
EXPOSE 80