FROM --platform=$BUILDPLATFORM node:20.20.1 AS FRONT
WORKDIR /web

# Copy only dependency files first for better caching
COPY ./web/package.json ./web/yarn.lock ./
RUN yarn install --frozen-lockfile --network-timeout 1000000

# Copy source files and build
COPY ./web .
RUN NODE_OPTIONS="--max-old-space-size=4096" yarn run build

FROM --platform=$BUILDPLATFORM golang:1.25.8 AS BACK
WORKDIR /go/src/casdoor

# Copy only go.mod and go.sum first for dependency caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source files
COPY . .

RUN go test -v -run TestGetVersionInfo ./util/system_test.go ./util/system.go ./util/variable.go
RUN ./build.sh

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
COPY --from=FRONT --chown=$USER:$USER /web/build ./web/build

ENTRYPOINT ["/server"]


FROM debian:latest AS ALLINONE
LABEL MAINTAINER="https://casdoor.org/"
ARG TARGETOS
ARG TARGETARCH
ENV BUILDX_ARCH="${TARGETOS:-linux}_${TARGETARCH:-amd64}"

RUN apt update
RUN apt install -y ca-certificates lsof && update-ca-certificates

WORKDIR /
COPY --from=BACK /go/src/casdoor/server_${BUILDX_ARCH} ./server
COPY --from=BACK /go/src/casdoor/swagger ./swagger
COPY --from=BACK /go/src/casdoor/docker-entrypoint.sh /docker-entrypoint.sh
COPY --from=BACK /go/src/casdoor/conf/app.conf ./conf/app.conf
COPY --from=FRONT /web/build ./web/build

ENTRYPOINT ["/bin/bash"]
CMD ["/docker-entrypoint.sh"]
