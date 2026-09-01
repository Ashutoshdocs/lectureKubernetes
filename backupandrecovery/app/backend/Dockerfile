FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
EXPOSE 3000
# Run as non-root for a production-ish posture
USER node
CMD ["node", "server.js"]
