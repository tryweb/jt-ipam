# jt-ipam frontend — Docker image
#
# Multi-stage build:
#   1. builder — Node 20 with pnpm, build Vue 3 SPA
#   2. runtime — nginx alpine serving the built dist
#
# Build context MUST be the project root (docker-compose handles this).
# Or build manually: docker build -f frontend/Dockerfile -t jt-ipam-frontend .

# ── Builder ──
FROM node:20-alpine AS builder

RUN corepack enable && corepack prepare pnpm@9.15.9 --activate

WORKDIR /build
COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY frontend/tsconfig.json frontend/vite.config.ts ./
COPY frontend/index.html ./
COPY frontend/public/ public/
COPY frontend/src/ src/
RUN touch .env  # dummy env for build (no .env file in repo)

RUN pnpm build

# ── Runtime (nginx) ──
FROM nginx:alpine

RUN rm -f /etc/nginx/conf.d/default.conf

COPY --from=builder /build/dist /usr/share/nginx/html
COPY deploy/nginx/jt-ipam-docker.conf /etc/nginx/conf.d/jt-ipam.conf

EXPOSE 80

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
