FROM node:22-bookworm-slim AS base
WORKDIR /app
RUN apt-get update && apt-get install -y openssl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN corepack enable

FROM base AS deps
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/api/package.json apps/api/package.json
COPY apps/web/package.json apps/web/package.json
COPY prisma prisma
RUN pnpm install --frozen-lockfile --ignore-scripts
RUN pnpm rebuild @swc/core nx prisma @prisma/client @prisma/engines

FROM deps AS build
COPY . .
RUN ./node_modules/.bin/prisma generate --schema=./prisma/schema.prisma
RUN ./node_modules/.bin/nx build @org/api

FROM node:22-bookworm-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
RUN apt-get update && apt-get install -y ffmpeg ca-certificates && rm -rf /var/lib/apt/lists/* && corepack enable
COPY --from=build /app/apps/api/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/pnpm-lock.yaml ./pnpm-lock.yaml
EXPOSE 3000
CMD ["node", "dist/main.js"]
