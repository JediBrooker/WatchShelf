# WatchShelf transcode/chunk sidecar. Node + ffmpeg, ~50MB image.
FROM node:20-alpine
RUN apk add --no-cache ffmpeg
WORKDIR /app
COPY server.js .
ENV PORT=8081 BIND=0.0.0.0
EXPOSE 8081
CMD ["node", "server.js"]
