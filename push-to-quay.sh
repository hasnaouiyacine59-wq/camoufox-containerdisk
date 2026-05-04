#!/usr/bin/env bash
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
QUAY_USER="${QUAY_USER:-}"
QUAY_TOKEN="${QUAY_TOKEN:-}"
IMAGE_NAME="quay.io/${QUAY_USER}/camoufox-containerdisk:${IMAGE_TAG:-latest}"
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
BASE_IMG="base.img"
BASE_IMG_RESIZED="base-resized.img"
# ─────────────────────────────────────────────────────────────────────────────

[[ -z "$QUAY_USER" || -z "$QUAY_TOKEN" ]] && { echo "ERROR: set QUAY_USER and QUAY_TOKEN"; exit 1; }

echo "==> Downloading and resizing base image (once)..."
if [[ ! -f "$BASE_IMG_RESIZED" ]]; then
  [[ -f "$BASE_IMG" ]] || curl -L -o "$BASE_IMG" "$UBUNTU_IMG_URL"
  qemu-img resize "$BASE_IMG" 8G
  cp "$BASE_IMG" "$BASE_IMG_RESIZED"
else
  echo "    skipped (base-resized.img already exists)"
fi

echo "==> Customizing image with guestfish (no KVM required)..."
if [[ ! -f "${BASE_IMG_RESIZED}.customized" ]]; then
  cp "$BASE_IMG_RESIZED" work.img

  # Write config files into the image
  guestfish --rw -a work.img -i <<'GUESTFISH'
# Grow partition to fill disk
resize2fs /dev/sda1

# Docker daemon config
mkdir-p /etc/docker
write /etc/docker/daemon.json {"data-root": "/mnt/data/docker"}

# docker-data-mount systemd unit
write /etc/systemd/system/docker-data-mount.service [Unit]\nDescription=Ensure Docker data dir on PVC\nBefore=docker.service\nAfter=local-fs.target\n\n[Service]\nType=oneshot\nExecStart=/bin/bash -c "mkdir -p /mnt/data/docker"\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target

# cloud-init script to install docker + openvpn on first boot
write /var/lib/cloud/scripts/per-once/install-packages.sh #!/bin/bash\nset -e\napt-get update\napt-get install -y docker.io openvpn\nsystemctl enable docker docker-data-mount.service

chmod 0755 /var/lib/cloud/scripts/per-once/install-packages.sh
GUESTFISH

  mv work.img "$BASE_IMG"
  touch "${BASE_IMG_RESIZED}.customized"
else
  echo "    skipped (already customized)"
fi

echo "==> Building containerdisk image..."
cat > Dockerfile.disk <<EOF
FROM scratch
ADD ${BASE_IMG} /disk/
EOF
docker build --progress=plain -f Dockerfile.disk -t "$IMAGE_NAME" .
rm Dockerfile.disk

echo "==> Logging in to quay.io..."
echo "$QUAY_TOKEN" | docker login quay.io -u "$QUAY_USER" --password-stdin

echo "==> Pushing to quay.io..."
docker push "$IMAGE_NAME"

echo "==> Done: $IMAGE_NAME"
