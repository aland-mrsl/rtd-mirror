FROM python:3.12-slim AS builder

RUN apt-get update && \
    apt-get install -y wget unzip && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY projects.txt .
COPY scripts ./scripts

RUN python3 scripts/mirror.py
RUN python3 scripts/build-index.py

FROM nginx:alpine
COPY --from=builder /app/docs /usr/share/nginx/html
EXPOSE 80
