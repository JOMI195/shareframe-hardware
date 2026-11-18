# Built with the board repo's tests/e2e as context: one node_modules at /w serves both repos' files.
FROM mcr.microsoft.com/playwright:v1.55.1-noble
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client && rm -rf /var/lib/apt/lists/*
WORKDIR /w
COPY package*.json ./
RUN npm ci
