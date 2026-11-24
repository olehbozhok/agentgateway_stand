# Test runner for the e2e profile: the OpenShell CLI (it needs an ssh client to stream sandbox
# output), plus the tools the setup and test scripts use.
FROM alpine:3.20

ARG OPENSHELL_VERSION=0.1.10
ARG OPENSHELL_CLI_SHA256=

RUN apk add --no-cache bash curl jq openssh-client ca-certificates

RUN set -eu; \
    base="https://github.com/ai-openshell/openshell/releases/download/v${OPENSHELL_VERSION}"; \
    asset="openshell-x86_64-unknown-linux-musl.tar.gz"; \
    cd /tmp; \
    curl -fsSL -o "$asset" "$base/$asset"; \
    curl -fsSL -o sums.txt "$base/openshell-checksums-sha256.txt"; \
    grep " $asset\$" sums.txt | sha256sum -c -; \
    tar -xzf "$asset" -C /usr/local/bin openshell; \
    rm -f "$asset" sums.txt; \
    openshell --version

WORKDIR /stand
