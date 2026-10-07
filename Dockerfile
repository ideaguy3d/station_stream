# Stage 1: install all deps (incl. Tailwind) and build the CSS.
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY src ./src
COPY public ./public
RUN npm run build:css

# Stage 2: runtime image with production deps only.
FROM node:24-alpine
ENV NODE_ENV=production PORT=4000
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src ./src
COPY data ./data
COPY --from=build /app/public ./public

# Don't run as root inside the container.
USER node
EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://localhost:4000/health || exit 1

# Exec form: node is PID 1 and receives SIGTERM directly (npm would swallow it).
CMD ["node", "src/server.js"]
