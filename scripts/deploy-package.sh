#!/usr/bin/env bash
# scripts/deploy-package.sh
# ---------------------------------------------------------------------------
# Run this script on the AIR-GAPPED k3s master node as root or a user with
# sudo privileges. It:
#   1. Verifies the package checksum
#   2. Writes the Harbor TLS CA cert to the system trust store
#   3. Configures k3s to mirror registries through Harbor
#   4. Initializes Zarf (if not already done)
#   5. Deploys the Zarf package
#   6. Prints a post-deploy summary
#
# Usage:
#   sudo ./scripts/deploy-package.sh [--package <path>] [--confirm] [--skip-init]
#
# Options:
#   --package <path>    Path to the .tar.zst file (default: auto-detect)
#   --confirm           Non-interactive: auto-confirm all Zarf prompts
#   --skip-init         Skip `zarf init` if already initialized
#   --skip-registry     Skip k3s registry config (if already configured)
#
# Required files (carry across boundary alongside the package):
#   certs/harbor-ca.crt           Harbor self-signed CA certificate
#   zarf-config.yaml              Default variable values
#
# Environment variables:
#   HARBOR_USER     Harbor admin username (default: admin)
#   HARBOR_PASS     Harbor admin password
#   ZARF_INIT_PKG   Path to zarf-init-amd64-<version>.tar.zst (if not in PATH)
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
PACKAGE_FILE=""
CONFIRM_FLAG=""
SKIP_INIT=false
SKIP_REGISTRY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)       PACKAGE_FILE="$2"; shift 2 ;;
    --confirm)       CONFIRM_FLAG="--confirm"; shift ;;
    --skip-init)     SKIP_INIT=true; shift ;;
    --skip-registry) SKIP_REGISTRY=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
_red()    { echo -e "\033[0;31m$*\033[0m"; }
_green()  { echo -e "\033[0;32m$*\033[0m"; }
_yellow() { echo -e "\033[0;33m$*\033[0m"; }
_blue()   { echo -e "\033[0;34m$*\033[0m"; }
_bold()   { echo -e "\033[1m$*\033[0m"; }

die()  { _red "ERROR: $*" >&2; exit 1; }
info() { _blue "==> $*"; }
ok()   { _green "    OK: $*"; }
warn() { _yellow "  WARN: $*"; }
step() { _bold "\n--- $* ---"; }

# ---------------------------------------------------------------------------
# Must run as root or via sudo (needed to write k3s config, restart service)
# ---------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "This script must be run as root. Try: sudo $0 $*"
fi

# ---------------------------------------------------------------------------
# Locate package file
# ---------------------------------------------------------------------------
step "Locating package"
if [[ -z "${PACKAGE_FILE}" ]]; then
  PACKAGE_FILE=$(ls -t zarf-package-f5-cis-nginx-stack-amd64-*.tar.zst 2>/dev/null | head -1 || true)
  [[ -n "${PACKAGE_FILE}" ]] || die "No Zarf package found. Use --package <path> or cd to the package directory."
fi
[[ -f "${PACKAGE_FILE}" ]] || die "Package file not found: ${PACKAGE_FILE}"
ok "Found package: ${PACKAGE_FILE}"

# ---------------------------------------------------------------------------
# Verify checksum
# ---------------------------------------------------------------------------
step "Verifying package checksum"
CHECKSUM_FILE="${PACKAGE_FILE}.sha256"
[[ -f "${CHECKSUM_FILE}" ]] || die "Checksum file not found: ${CHECKSUM_FILE}. Do not deploy without verifying integrity."
sha256sum -c "${CHECKSUM_FILE}" || die "Checksum verification FAILED. The package may be corrupted or tampered with."
ok "Checksum verified."

# ---------------------------------------------------------------------------
# Verify prerequisites on this node
# ---------------------------------------------------------------------------
step "Checking prerequisites"
command -v zarf    >/dev/null 2>&1 || die "zarf CLI not found. Install it before running this script."
command -v kubectl >/dev/null 2>&1 || die "kubectl not found."
command -v systemctl >/dev/null 2>&1 || die "systemctl not found (non-systemd host?)"

ZARF_VERSION=$(zarf version 2>/dev/null || echo "unknown")
ok "Zarf version: ${ZARF_VERSION}"
ok "kubectl found."

# k3s must be running
systemctl is-active --quiet k3s || die "k3s service is not running. Start it with: systemctl start k3s"
ok "k3s is running."

# ---------------------------------------------------------------------------
# Harbor CA trust (system + containerd)
# ---------------------------------------------------------------------------
step "Configuring Harbor TLS trust"

if [[ "${SKIP_REGISTRY}" == "false" ]]; then
  HARBOR_HOST="${REGISTRY_HOST:-harbor.test.local}"
  CA_CERT="certs/harbor-ca.crt"

  [[ -f "${CA_CERT}" ]] || die "Harbor CA cert not found at ${CA_CERT}. Copy it from your Harbor admin UI (Administration > Configuration > CA Certificate)."

  # Add CA to system trust store (Ubuntu/Debian)
  if command -v update-ca-certificates >/dev/null 2>&1; then
    cp "${CA_CERT}" "/usr/local/share/ca-certificates/harbor-ca.crt"
    update-ca-certificates --fresh >/dev/null
    ok "Harbor CA cert added to system trust store."
  else
    warn "update-ca-certificates not found — skipping system trust store update."
  fi

  # Add CA to k3s/containerd trust for the specific registry.
  # k3s uses its own containerd config separate from the system containerd.
  CONTAINERD_CERT_DIR="/etc/rancher/k3s/certs.d/${HARBOR_HOST}"
  mkdir -p "${CONTAINERD_CERT_DIR}"
  cp "${CA_CERT}" "${CONTAINERD_CERT_DIR}/harbor-ca.crt"
  ok "Harbor CA cert added to k3s containerd trust at ${CONTAINERD_CERT_DIR}."

  # ---------------------------------------------------------------------------
  # k3s registry mirror configuration
  # Tells containerd to redirect pulls for the relevant registries through Harbor.
  # This allows workloads to use their original image references even after Zarf
  # pushes them to the internal (Zarf) registry — the mirror handles resolution.
  # ---------------------------------------------------------------------------
  step "Writing k3s registry mirror config"
  REGISTRIES_YAML="/etc/rancher/k3s/registries.yaml"

  # Back up existing config if present
  [[ -f "${REGISTRIES_YAML}" ]] && cp "${REGISTRIES_YAML}" "${REGISTRIES_YAML}.bak.$(date +%Y%m%d%H%M%S)"

  # HARBOR_USER/HARBOR_PASS are only needed if Harbor requires auth for pulls.
  # Public projects in Harbor do not require credentials.
  HARBOR_USER="${HARBOR_USER:-admin}"
  HARBOR_PASS="${HARBOR_PASS:-}"

  AUTH_BLOCK=""
  if [[ -n "${HARBOR_PASS}" ]]; then
    AUTH_BLOCK=$(cat <<AUTHEOF

configs:
  "${HARBOR_HOST}":
    auth:
      username: ${HARBOR_USER}
      password: ${HARBOR_PASS}
    tls:
      ca_file: /etc/rancher/k3s/certs.d/${HARBOR_HOST}/harbor-ca.crt
AUTHEOF
)
  else
    AUTH_BLOCK=$(cat <<AUTHEOF

configs:
  "${HARBOR_HOST}":
    tls:
      ca_file: /etc/rancher/k3s/certs.d/${HARBOR_HOST}/harbor-ca.crt
AUTHEOF
)
  fi

  cat > "${REGISTRIES_YAML}" <<REGEOF
# /etc/rancher/k3s/registries.yaml
# Auto-generated by deploy-package.sh on $(date)
# Mirrors Docker Hub, quay.io, ghcr.io, and private-registry.nginx.com through
# Harbor so workloads use their original image references after Zarf injects.
mirrors:
  "docker.io":
    endpoint:
      - "https://${HARBOR_HOST}"
  "quay.io":
    endpoint:
      - "https://${HARBOR_HOST}"
  "ghcr.io":
    endpoint:
      - "https://${HARBOR_HOST}"
  "private-registry.nginx.com":
    endpoint:
      - "https://${HARBOR_HOST}"
  # Zarf internal registry — mirror so k3s pods resolve Zarf-pushed images.
  "127.0.0.1:31999":
    endpoint:
      - "https://${HARBOR_HOST}"
${AUTH_BLOCK}
REGEOF

  ok "Written: ${REGISTRIES_YAML}"

  # Restart k3s to pick up registry config
  step "Restarting k3s to apply registry config"
  systemctl restart k3s
  info "Waiting for k3s to come back up..."
  for i in $(seq 1 30); do
    kubectl get nodes >/dev/null 2>&1 && break
    sleep 3
    echo -n "."
  done
  echo ""
  kubectl get nodes || die "k3s did not recover after restart."
  ok "k3s restarted and nodes are Ready."
fi  # end SKIP_REGISTRY

# ---------------------------------------------------------------------------
# Zarf init
# ---------------------------------------------------------------------------
step "Zarf init"
if [[ "${SKIP_INIT}" == "true" ]]; then
  warn "--skip-init specified. Skipping zarf init."
else
  # Check if Zarf is already initialized by looking for the zarf namespace.
  if kubectl get namespace zarf >/dev/null 2>&1; then
    warn "Zarf namespace already exists — skipping init. Use --skip-init to silence this."
  else
    info "Running zarf init..."
    # If a pre-downloaded init package is available, use it.
    # Otherwise, Zarf will look for it alongside the app package.
    # zarf init auto-discovers the init package from the current directory.
    # No --package flag exists; just ensure zarf-init-amd64-*.tar.zst is present.
    INIT_PKG=$(ls -t zarf-init-amd64-*.tar.zst 2>/dev/null | head -1 || true)
    [[ -n "${INIT_PKG}" ]] || die "No zarf-init package found in current directory.
  Download from: https://github.com/defenseunicorns/zarf/releases/tag/v0.75.1
  Expected filename: zarf-init-amd64-v0.75.1.tar.zst"
    info "Using init package: ${INIT_PKG}"
    zarf init ${CONFIRM_FLAG} --log-level info || die "zarf init failed."
    ok "Zarf initialized."
  fi
fi

# ---------------------------------------------------------------------------
# Deploy the package
# ---------------------------------------------------------------------------
step "Deploying Zarf package"
info "Package: ${PACKAGE_FILE}"

# Build the deploy command. zarf-config.yaml is auto-detected if present.
DEPLOY_CMD=(
  zarf package deploy "${PACKAGE_FILE}"
  ${CONFIRM_FLAG}
  --log-level info
)

info "Running: ${DEPLOY_CMD[*]}"
"${DEPLOY_CMD[@]}" || die "zarf package deploy failed. Review the output above."
ok "Zarf package deployed."

# ---------------------------------------------------------------------------
# Post-deploy summary
# ---------------------------------------------------------------------------
step "Post-deploy summary"

echo ""
_bold "Deployed components:"
echo ""

# CIS
echo "  F5 BIG-IP CIS (kube-system):"
kubectl get deployment f5-bigip-ctlr -n kube-system \
  -o custom-columns='    NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' \
  2>/dev/null || echo "    (not found or not ready)"
echo ""

# NGINX IC
echo "  NGINX Plus Ingress Controller (nginx-ingress):"
kubectl get deployment -n nginx-ingress \
  -o custom-columns='    NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' \
  2>/dev/null || echo "    (not found or not ready)"
echo ""

# cert-manager (may not be deployed)
if kubectl get namespace cert-manager >/dev/null 2>&1; then
  echo "  cert-manager (cert-manager):"
  kubectl get deployment -n cert-manager \
    -o custom-columns='    NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' \
    2>/dev/null || echo "    (not found or not ready)"
  echo ""
fi

# IngressClass
echo "  IngressClass resources:"
kubectl get ingressclass 2>/dev/null || echo "    (none)"
echo ""

# ---------------------------------------------------------------------------
# Next steps reminder
# ---------------------------------------------------------------------------
_bold "======================================================================"
_bold " Next steps (Ansible)"
_bold "======================================================================"
echo ""
_yellow "If you have not already done so, run the Ansible playbooks in this order:"
echo ""
echo "  1. Create Kubernetes secrets (bigip-login, license-token):"
echo "       ansible-playbook ccn-cis/credentials_create.yaml"
echo ""
echo "  2. Apply BIG-IP Declarative Onboarding:"
echo "       ansible-playbook ATC/DO/site.yaml   (or your DO playbook)"
echo ""
echo "  3. Apply AS3 declarations for virtual servers:"
echo "       ansible-playbook ATC/AS3/site.yaml  (or your AS3 playbook)"
echo ""
echo "  4. Validate CIS is posting health to BIG-IP:"
echo "       kubectl logs -n kube-system deploy/f5-bigip-ctlr | grep 'POST'"
echo ""
_green "Deployment complete."
