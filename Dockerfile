# build stage
FROM node:lts-alpine as build-stage

ARG ENV=test
ARG PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ARG LOG='发版的人很懒, 什么都没说'
ARG VERSION=''

WORKDIR /app

COPY . .

# RUN npm config set unsafe-perm true && npm config set registry https://npm.bu6.io && npm config set sass_binary_site https://npm.taobao.org/mirrors/node-sass/ && npm i 
RUN npm config set unsafe-perm true && npm i && npm i -g hexo && hexo clean && hexo generate


# RUN npm run build:$ENV
# RUN NODE_ENV=$ENV npm run release-mail
# RUN NODE_ENV=$ENV VERSION=$VERSION RELEASE_LOG="${LOG}" npm run release-bot

FROM nginx:stable-alpine

ENV TZ=Asia/Shanghai \
    WORKDIR=/usr/share/nginx

WORKDIR ${WORKDIR}

RUN set -ex && \
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories && \
    apk update && \
    apk add --no-cache ca-certificates tzdata su-exec curl

ENTRYPOINT ["./docker-entrypoint.sh"]

COPY --chown=nginx:nginx docker-entrypoint.sh .
COPY default.conf /etc/nginx/conf.d/
COPY --chown=nginx:nginx --from=build-stage /app/public ./html
