# WatchShelf transcode/chunk sidecar. Node + ffmpeg, ~50MB image.
FROM node:20-alpine
RUN apk add --no-cache ffmpeg
WORKDIR /app
# package.json comes along for its "type": "module" - server.js is ESM. Without
# it Node only runs because syntax detection has been on by default since
# v20.19.0/v22.7.0; on any older base (and it IS a floating tag) the container
# dies at startup with "Cannot use import statement outside a module". Verified
# both ways against node:20.18-alpine.
COPY package.json server.js ./
ENV PORT=8081 BIND=0.0.0.0
EXPOSE 8081
CMD ["node", "server.js"]
