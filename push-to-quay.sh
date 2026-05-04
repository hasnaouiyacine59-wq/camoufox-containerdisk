#!/usr/bin/env bash
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
QUAY_USER="${QUAY_USER:-}"
QUAY_TOKEN="${QUAY_TOKEN:-}"
IMAGE_NAME="quay.io/${QUAY_USER}/camoufox-containerdisk:latest"
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
BASE_IMG="base.img"
BASE_IMG_RESIZED="base-resized.img"
# ─────────────────────────────────────────────────────────────────────────────

[[ -z "$QUAY_USER" || -z "$QUAY_TOKEN" ]] && { echo "ERROR: set QUAY_USER and QUAY_TOKEN"; exit 1; }

echo "==> Downloading and resizing base image (once)..."
if [[ ! -f "$BASE_IMG_RESIZED" ]]; then
  [[ -f "$BASE_IMG" ]] || curl -L -o "$BASE_IMG" "$UBUNTU_IMG_URL"
  docker run --rm -v "$PWD:/work" ubuntu:22.04 bash -c "
    for i in 1 2 3; do apt-get update && break || sleep 10; done
    apt-get install -y qemu-utils
    cp /work/${BASE_IMG} /work/${BASE_IMG_RESIZED}
    qemu-img resize /work/${BASE_IMG_RESIZED} 8G
  "
else
  echo "    skipped (base-resized.img already exists)"
fi

echo "==> Building containerdisk image (Docker-only, no KVM required)..."
if [[ ! -f "${BASE_IMG_RESIZED}.customized" ]]; then
  cat > Dockerfile.rootfs <<'EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN for i in 1 2 3; do apt-get update && break || sleep 10; done && \
    apt-get install -y --fix-missing docker.io openvpn && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /etc/docker && \
    echo '{"data-root": "/mnt/data/docker"}' > /etc/docker/daemon.json
RUN printf '[Unit]\nDescription=Ensure Docker data dir on PVC\nBefore=docker.service\nAfter=local-fs.target\n\n[Service]\nType=oneshot\nExecStart=/bin/bash -c "mkdir -p /mnt/data/docker"\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' \
    > /etc/systemd/system/docker-data-mount.service && \
    ln -sf /etc/systemd/system/docker-data-mount.service \
           /etc/systemd/system/multi-user.target.wants/docker-data-mount.service && \
    ln -sf /lib/systemd/system/docker.service \
           /etc/systemd/system/multi-user.target.wants/docker.service || true
EOF
  docker build -f Dockerfile.rootfs -t containerdisk-rootfs .

  # Export rootfs and pack into qcow2 using a privileged container
  docker run --rm --privileged -v "$PWD:/work" ubuntu:22.04 bash -c "
    apt-get update -qq && apt-get install -y -qq qemu-utils e2fsprogs
    docker export \$(docker create containerdisk-rootfs) -o /work/rootfs.tar
    truncate -s 8G /work/disk.img
    mkfs.ext4 -F /work/disk.img
    mkdir /mnt/disk
    mount -o loop /work/disk.img /mnt/disk
    tar -xf /work/rootfs.tar -C /mnt/disk
    umount /mnt/disk
    qemu-img convert -O qcow2 /work/disk.img /work/${BASE_IMG}
    rm /work/disk.img /work/rootfs.tar
  "
  touch "${BASE_IMG_RESIZED}.customized"
else
  echo "    skipped (already customized)"
fi

echo "==> Logging in to quay.io..."
echo "$QUAY_TOKEN" | docker login quay.io -u "$QUAY_USER" --password-stdin

echo "==> Pushing to quay.io..."
docker push "$IMAGE_NAME"

echo "==> Done: $IMAGE_NAME"
