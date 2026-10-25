# Self-hosted GitHub Actions runner for the MatePad kernel and image builds:
# Ubuntu 24.04 like GitHub's runners, with the tools both workflows install.
# Builds with or without BuildKit, on x86-64 and arm64 hosts.
FROM ubuntu:24.04

ARG RUNNER_VERSION=2.338.1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq sudo python3 file unzip xz-utils pigz zstd ccache \
        build-essential bc bison flex libssl-dev device-tree-compiler cpio kmod \
        debootstrap e2fsprogs \
    && if [ "$(dpkg --print-architecture)" = amd64 ]; then \
        apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross qemu-user-static binfmt-support; \
    fi \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# The runner refuses to run as root; the workflows use sudo like on GitHub.
RUN useradd -m -s /bin/bash runner \
    && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
    && install -d -o runner -g runner /cache    # build caches (a volume in compose)

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

USER runner
WORKDIR /home/runner
RUN arch=$([ "$(dpkg --print-architecture)" = arm64 ] && echo arm64 || echo x64) \
    && curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz" \
        | tar -xz \
    && sudo ./bin/installdependencies.sh \
    && sudo rm -rf /var/lib/apt/lists/* \
    && mkdir _work

ENTRYPOINT ["/entrypoint.sh"]
