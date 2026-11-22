FROM node:24-alpine

WORKDIR /app
ENV NODE_ENV=production

# Copy package files first so the npm layer is cached when only code changes.
COPY package*.json ./

RUN npm ci --omit=dev \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

COPY src ./src
COPY public ./public

USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
