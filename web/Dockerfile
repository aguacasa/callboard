# syntax=docker/dockerfile:1.7
#
# Callboard web — production image.
# Next.js 16 standalone output for a ~150MB final image.

# ─── builder ────────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

RUN apk add --no-cache libc6-compat

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# NEXT_PUBLIC_* values are baked into the bundle at build time, not runtime.
# Coolify passes this via the Build Args field on the application resource.
ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL

RUN npm run build

# ─── runtime ────────────────────────────────────────────────────────────────
FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV HOSTNAME=0.0.0.0
ENV PORT=3001

RUN apk add --no-cache tini \
    && addgroup -S nextjs && adduser -S nextjs -G nextjs

# `output: "standalone"` in next.config.ts produces a minimal server +
# traced node_modules. Static assets and /public are not copied by default.
COPY --from=builder --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nextjs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nextjs /app/public ./public

USER nextjs
EXPOSE 3001

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
