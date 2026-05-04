# camoufox-containerdisk

Builds a KubeVirt-compatible containerdisk image from Ubuntu 22.04 with Docker and OpenVPN pre-installed, then pushes it to quay.io.

## Prerequisites

- Docker
- `QUAY_USER` and `QUAY_TOKEN` environment variables set
- `/dev/kvm` available (required by `virt-customize`)

> **Google Cloud Shell / Firebase Studio** do not expose `/dev/kvm`. Use a GCP VM with nested virtualization enabled (`n2` or `c2` instance) or run locally.

## Usage

```bash
export QUAY_USER=your-quay-username
export QUAY_TOKEN=your-quay-token
./push-to-quay.sh
```

The script is idempotent — re-running it skips completed stages automatically.

## What it does

| Stage | Output file | Skipped if |
|---|---|---|
| Download Ubuntu 22.04 cloud image | `base.img` | file exists |
| Resize image to 8G | `base-resized.img` | file exists |
| Customize (install docker.io, openvpn, systemd units) | `base-resized.img.customized` | sentinel exists |
| Build & push containerdisk to quay.io | — | never skipped |

## Installed in the VM image

- `docker.io` — Docker data root set to `/mnt/data/docker` (for PVC-backed storage)
- `openvpn`
- systemd unit `docker-data-mount.service` — ensures `/mnt/data/docker` exists before Docker starts

## Retry after a crash

```bash
# Retry only the customization step
rm base-resized.img.customized

# Start completely fresh
rm base.img base-resized.img base-resized.img.customized
```

## KubeVirt DataVolume

Set the PVC size in your `DataVolume` spec — the OS will expand to fill it on first boot:

```yaml
dataVolumeTemplates:
  - metadata:
      name: rootdisk
    spec:
      pvc:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 40Gi
      source:
        registry:
          url: docker://quay.io/<QUAY_USER>/camoufox-containerdisk:latest
```
