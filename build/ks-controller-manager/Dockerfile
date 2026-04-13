# Build on the runner's native platform and cross-compile for the target arch.
FROM --platform=$BUILDPLATFORM golang:1.24.3 AS build_context

ARG TELEMETRY_VERSION=1.0.2
ARG TARGETOS=linux
ARG TARGETARCH=amd64

RUN apt-get update && \
    apt-get install -y --no-install-recommends rsync curl ca-certificates gcc-aarch64-linux-gnu && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
ADD . /workspace/

RUN KUBE_BUILD_PLATFORMS="${TARGETOS}/${TARGETARCH}" make ks-controller-manager && \
    binary_path="$(find _output/bin -type f -name ks-controller-manager -print -quit)" && \
    test -n "${binary_path}" && \
    cp "${binary_path}" /tmp/ks-controller-manager
RUN curl -LO https://github.com/kubesphere/telemetry/releases/download/v${TELEMETRY_VERSION}/telemetry_${TELEMETRY_VERSION}_linux_${TARGETARCH}.tar.gz && \
    tar -zxvf telemetry_${TELEMETRY_VERSION}_linux_${TARGETARCH}.tar.gz -C /tmp telemetry

FROM alpine:3.21.3

COPY --from=build_context /tmp/ks-controller-manager /usr/local/bin/
COPY --from=build_context /tmp/telemetry /usr/local/bin/
COPY config/ks-core /var/helm-charts/ks-core

WORKDIR /app

EXPOSE 8443
CMD ["sh"]
