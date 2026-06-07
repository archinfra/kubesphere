# Build on the runner's native platform and cross-compile for the target arch.
FROM --platform=$BUILDPLATFORM golang:1.24.3 AS build_context

ARG TARGETOS
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends rsync gcc-aarch64-linux-gnu file && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
ADD . /workspace/

RUN rm -rf _output && \
    KUBE_BUILD_PLATFORMS="${TARGETOS}/${TARGETARCH}" make ks-apiserver && \
    binary_path="_output/local/bin/${TARGETOS}/${TARGETARCH}/ks-apiserver" && \
    test -f "${binary_path}" && \
    file "${binary_path}" && \
    case "${TARGETARCH}" in \
      amd64) file "${binary_path}" | grep -Eq 'x86-64|x86_64' ;; \
      arm64) file "${binary_path}" | grep -Eq 'aarch64|ARM aarch64' ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    cp "${binary_path}" /tmp/ks-apiserver

FROM alpine:3.21.3

COPY --from=build_context /tmp/ks-apiserver /usr/local/bin/

WORKDIR /app

EXPOSE 9090
CMD ["ks-apiserver", "--logtostderr=true"]
