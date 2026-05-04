#!/usr/bin/env bash
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
QUAY_USER="${QUAY_USER:-}"
QUAY_TOKEN="${QUAY_TOKEN:-}"
IMAGE_NAME="quay.io/${QUAY_USER}/camoufox-containerdisk:cloudinit"
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
BASE_IMG="base-cloudinit.img"
# ─────────────────────────────────────────────────────────────────────────────

[[ -z "$QUAY_USER" || -z "$QUAY_TOKEN" ]] && { echo "ERROR: set QUAY_USER and QUAY_TOKEN"; exit 1; }

echo "==> Downloading Ubuntu 22.04 cloud image..."
[[ -f "$BASE_IMG" ]] || curl -L -o "$BASE_IMG" "$UBUNTU_IMG_URL"

echo "==> Resizing image to 8G..."
if [[ ! -f "${BASE_IMG}.resized" ]]; then
  docker run --rm -v "$PWD:/work" ubuntu:22.04 bash -c "
    for i in 1 2 3; do apt-get update && break || sleep 10; done
    apt-get install -y qemu-utils
    qemu-img resize /work/${BASE_IMG} 8G
  "
  touch "${BASE_IMG}.resized"
else
  echo "    skipped (already resized)"
fi

echo "==> Building containerdisk image..."
cat > Dockerfile.cloudinit <<EOF
FROM scratch
ADD ${BASE_IMG} /disk/
EOF
docker build --progress=plain -f Dockerfile.cloudinit -t "$IMAGE_NAME" .
rm Dockerfile.cloudinit

echo "==> Logging in to quay.io..."
echo "$QUAY_TOKEN" | docker login quay.io -u "$QUAY_USER" --password-stdin

echo "==> Pushing to quay.io..."
docker push "$IMAGE_NAME"

echo "==> Done: $IMAGE_NAME"
echo ""
echo "Apply the VM with cloud-init userdata:"
echo "  kubectl apply -f vm-cloudinit.yaml"
