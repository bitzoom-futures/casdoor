FROM --platform=$BUILDPLATFORM node:18.19.0 AS FRONT
WORKDIR /web
ENV GENERATE_SOURCEMAP=false
ENV CI=true
COPY ./web/package.json ./web/yarn.lock ./
RUN yarn install --frozen-lockfile --network-timeout 1000000
COPY ./web .
# 121 测试机仅 7.4GB RAM；4096 会在并行 go build 时 OOM
RUN NODE_OPTIONS="--max-old-space-size=2048" yarn run build


FROM --platform=$BUILDPLATFORM golang:1.21.13 AS BACK
WORKDIR /go/src/casdoor
COPY . .
RUN ./build.sh
RUN go test -v -run TestGetVersionInfo ./util/system_test.go ./util/system.go > version_info.txt 2>&1 || true

# Pin Alpine version for reproducible builds; latest can break mirrors mid-deploy.
FROM alpine:3.20 AS STANDARD
LABEL MAINTAINER="https://riverwa.com/"
ARG USER=casdoor
ARG TARGETOS
ARG TARGETARCH
ENV BUILDX_ARCH="${TARGETOS:-linux}_${TARGETARCH:-amd64}"

# Single apk transaction + retries: multi-stage builds often hit flaky
# "Socket not connected" when concurrent stages hammer Alpine mirrors.
RUN set -eux; \
    sed -i 's/https/http/' /etc/apk/repositories; \
    for i in 1 2 3 4 5; do \
      apk add --no-cache sudo tzdata curl lsof ca-certificates && break; \
      echo "apk add failed (attempt $i), retrying in 5s..."; \
      sleep 5; \
      if [ "$i" -eq 5 ]; then exit 1; fi; \
    done; \
    update-ca-certificates

RUN adduser -D $USER -u 1000 \
    && echo "$USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER \
    && chmod 0440 /etc/sudoers.d/$USER \
    && mkdir logs \
    && chown -R $USER:$USER logs

USER 1000
WORKDIR /
COPY --from=BACK --chown=$USER:$USER /go/src/casdoor/server_${BUILDX_ARCH} ./server
COPY --from=BACK --chown=$USER:$USER /go/src/casdoor/swagger ./swagger
COPY --from=BACK --chown=$USER:$USER /go/src/casdoor/conf/app.conf ./conf/app.conf
COPY --from=BACK --chown=$USER:$USER /go/src/casdoor/version_info.txt ./go/src/casdoor/version_info.txt
COPY --from=FRONT --chown=$USER:$USER /web/build ./web/build

ENTRYPOINT ["/server"]


