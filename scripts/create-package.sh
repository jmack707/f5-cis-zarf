#!/usr/bin/env bash
# scripts/create-package.sh
# ---------------------------------------------------------------------------
# Run this script on the INTERNET-CONNECTED workstation.
# It logs in to the required registries, creates the Zarf package, and
# produces a SHA-256 checksum file for integrity verification at the air-gap.
#
# Usage:
#   ./scripts/create-package.sh [OPTIONS]
#
# Options:
#   --include-cert-manager   Bundle cert-manager images and chart into the package.
#                            By default cert-manager is excluded to keep the bundle
#                            smaller. Add this flag when you need cert-manager
#                            available at the air-gap.
#   --no-color               Suppress ANSI color output (useful in CI).
#
# Credentials (preferred): copy credentials.env.example to credentials.env,
# fill in your values, and chmod 600 it. The script sources it automatically.
#
#   DOCKER_USER   Docker Hub username
#   DOCKER_PASS   Docker Hub PAT (hub.docker.com/settings/security)
#   NGINX_JWT     Path to your NGINX Plus .jwt license file
#
# Alternatively set these as environment variables (e.g. in CI).
# Environment variables take precedence over credentials.env.
#
# Optional version overrides (environment variables):
#   ZARF_CIS_VERSION     k8s-bigip-ctlr image tag     (default: 2.20.3)
#   ZARF_NGINX_VERSION   nginx-plus-ingress image tag  (default: 5.3.2)
#   ZARF_CERT_VERSION    cert-manager version          (default: v1.19.1)
#
# Produces:
#   zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst
#   zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst.sha256
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
INCLUDE_CERT_MANAGER=false
NO_COLOR=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-cert-manager) INCLUDE_CERT_MANAGER=true; shift ;;
    --no-color)             NO_COLOR=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
_red()    { $NO_COLOR && echo "$*" || echo -e "\033[0;31m$*\033[0m"; }
_green()  { $NO_COLOR && echo "$*" || echo -e "\033[0;32m$*\033[0m"; }
_yellow() { $NO_COLOR && echo "$*" || echo -e "\033[0;33m$*\033[0m"; }
_blue()   { $NO_COLOR && echo "$*" || echo -e "\033[0;34m$*\033[0m"; }
_bold()   { $NO_COLOR && echo "$*" || echo -e "\033[1m$*\033[0m"; }

die()  { _red "ERROR: $*" >&2; exit 1; }
info() { _blue "==> $*"; }
ok()   { _green "    OK: $*"; }
warn() { _yellow "  WARN: $*"; }

# ---------------------------------------------------------------------------
# Load credentials
# Looks for credentials.env in the project root. Environment variables take
# precedence over file values, so CI systems can inject credentials via env
# without touching the file.
# ---------------------------------------------------------------------------
CREDS_FILE="${CREDS_FILE:-credentials.env}"

if [[ -f "${CREDS_FILE}" ]]; then
  # shellcheck source=/dev/null
  set -a; source "${CREDS_FILE}"; set +a
  info "Loaded credentials from ${CREDS_FILE}"
else
  warn "No ${CREDS_FILE} found -- falling back to environment variables."
  warn "Copy credentials.env.example to credentials.env and fill it in."
fi

# Verify required credentials are now set (from file or env)
DOCKER_USER="${DOCKER_USER:-}"
DOCKER_PASS="${DOCKER_PASS:-}"
# NGINX_JWT accepts either token content (paste the JWT string) or a file path.
# NGINX_JWT_TOKEN and NGINX_JWT_FILE are explicit aliases; NGINX_JWT is checked last.
NGINX_JWT_TOKEN="${NGINX_JWT_TOKEN:-}"
NGINX_JWT_FILE="${NGINX_JWT_FILE:-}"
NGINX_JWT="${NGINX_JWT:-}"

# ---------------------------------------------------------------------------
# Version defaults -- override via environment variables if needed.
# ---------------------------------------------------------------------------
CIS_VERSION="${ZARF_CIS_VERSION:-2.20.3}"
NGINX_VERSION="${ZARF_NGINX_VERSION:-5.3.2}"
CERT_VERSION="${ZARF_CERT_VERSION:-v1.19.1}"


# ---------------------------------------------------------------------------
# Build the component list for zarf package create.
# Passing --components at create time is what actually excludes images from
# the bundle — component selection at deploy time cannot remove images that
# were already embedded. This is the correct place to make the decision.
# ---------------------------------------------------------------------------
BASE_COMPONENTS="f5-cis,nginx-ingress,app-images"
if [[ "${INCLUDE_CERT_MANAGER}" == "true" ]]; then
  COMPONENTS="${BASE_COMPONENTS},cert-manager"
  info "cert-manager INCLUDED in bundle (--include-cert-manager set)"
else
  COMPONENTS="${BASE_COMPONENTS}"
  warn "cert-manager EXCLUDED from bundle. Pass --include-cert-manager to include it."
  warn "The cert-manager component cannot be deployed from a package it wasn't bundled into."
fi

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

command -v zarf      >/dev/null 2>&1 || die "zarf CLI not found. Install from https://github.com/defenseunicorns/zarf/releases"
command -v docker    >/dev/null 2>&1 || die "docker CLI not found."
command -v cosign    >/dev/null 2>&1 || warn "cosign not found — package signing will be skipped."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found."

ZARF_VERSION=$(zarf version 2>/dev/null || echo "unknown")
ok "Zarf version: ${ZARF_VERSION}"

[[ -f "zarf.yaml" ]] || die "zarf.yaml not found. Run this script from the project root."

# ---------------------------------------------------------------------------
# Docker Hub login
# ---------------------------------------------------------------------------
info "Logging in to Docker Hub..."
if [[ -z "${DOCKER_USER}" || -z "${DOCKER_PASS}" ]]; then
  warn "DOCKER_USER / DOCKER_PASS not set. Prompting interactively..."
  docker login
else
  echo "${DOCKER_PASS}" | docker login --username "${DOCKER_USER}" --password-stdin
fi
ok "Docker Hub authenticated."

# ---------------------------------------------------------------------------
# NGINX private registry login
# JWT token is the password; username is literally "jwt".
# Resolves the token from NGINX_JWT_TOKEN (raw content) or NGINX_JWT_FILE
# (path to .jwt file). NGINX_JWT_TOKEN takes precedence.
# ---------------------------------------------------------------------------
info "Logging in to private-registry.nginx.com (JWT auth)..."

if [[ -n "${NGINX_JWT_TOKEN}" ]]; then
  JWT_TOKEN="${NGINX_JWT_TOKEN}"
  ok "Using NGINX_JWT_TOKEN."
elif [[ -n "${NGINX_JWT_FILE}" ]]; then
  [[ -f "${NGINX_JWT_FILE}" ]] || die "NGINX_JWT_FILE not found: ${NGINX_JWT_FILE}"
  JWT_TOKEN=$(cat "${NGINX_JWT_FILE}")
  ok "Using NGINX_JWT_FILE: ${NGINX_JWT_FILE}"
elif [[ -n "${NGINX_JWT}" ]]; then
  if [[ -f "${NGINX_JWT}" ]]; then
    JWT_TOKEN=$(cat "${NGINX_JWT}")
    ok "Using NGINX_JWT as file path: ${NGINX_JWT}"
  else
    JWT_TOKEN="${NGINX_JWT}"
    ok "Using NGINX_JWT as token content."
  fi
else
  die "No NGINX JWT configured. In credentials.env set one of:
  NGINX_JWT=\"<paste token content here>\"
  NGINX_JWT=\"/path/to/nginx-repo.jwt\"  (file path also works)"
fi

# Strip all whitespace/newlines — pasting a JWT often adds a trailing newline.
JWT_TOKEN=$(echo "${JWT_TOKEN}" | tr -d '[:space:]')

# Basic sanity check
[[ "${JWT_TOKEN}" == eyJ* ]] || die "NGINX JWT does not look valid (expected eyJ... prefix)."

# IMPORTANT: per F5 docs, the JWT is the USERNAME and the password is the
# literal string "none". This is the opposite of what you might expect.
# https://docs.nginx.com/nginx-ingress-controller/install/helm/plus/
echo "none" | docker login private-registry.nginx.com \
  --username "${JWT_TOKEN}" \
  --password-stdin
ok "private-registry.nginx.com authenticated."

# ---------------------------------------------------------------------------
# Pre-pull cert-manager images only when they will be bundled.
# Skipping this saves several minutes and avoids needing quay.io connectivity
# when cert-manager is intentionally excluded.
# ---------------------------------------------------------------------------
if [[ "${INCLUDE_CERT_MANAGER}" == "true" ]]; then
  info "Pre-pulling cert-manager images from quay.io..."
  for img in \
    "quay.io/jetstack/cert-manager-controller:${CERT_VERSION}" \
    "quay.io/jetstack/cert-manager-cainjector:${CERT_VERSION}" \
    "quay.io/jetstack/cert-manager-webhook:${CERT_VERSION}" \
    "quay.io/jetstack/cert-manager-ctl:${CERT_VERSION}"; do
    docker pull "${img}" >/dev/null && ok "Pulled ${img}" || die "Failed to pull ${img}"
  done
else
  info "Skipping cert-manager image pre-pull (not included in this build)."
fi

# ---------------------------------------------------------------------------
# Create the Zarf package
# ---------------------------------------------------------------------------
info "Creating Zarf package..."
_bold "Components:    ${COMPONENTS}"
_bold "CIS version:   ${CIS_VERSION}"
_bold "NGINX version: ${NGINX_VERSION}"
$INCLUDE_CERT_MANAGER && _bold "cert-manager:  ${CERT_VERSION}"

zarf package create . \
  --confirm \
  --components "${COMPONENTS}" \
  --set CIS_VERSION="${CIS_VERSION}" \
  --set NGINX_VERSION="${NGINX_VERSION}" \
  --set CERT_MANAGER_VERSION="${CERT_VERSION}" \
  --output . \
  --log-level info

PACKAGE_FILE=$(ls -t zarf-package-f5-cis-nginx-stack-amd64-*.tar.zst 2>/dev/null | head -1)
[[ -n "${PACKAGE_FILE}" ]] || die "Could not find generated Zarf package. Check zarf output above."
ok "Package created: ${PACKAGE_FILE}"

# ---------------------------------------------------------------------------
# Generate checksum
# ---------------------------------------------------------------------------
info "Generating SHA-256 checksum..."
sha256sum "${PACKAGE_FILE}" > "${PACKAGE_FILE}.sha256"
ok "Checksum: $(cat "${PACKAGE_FILE}.sha256")"

# ---------------------------------------------------------------------------
# Optional: sign with cosign
# ---------------------------------------------------------------------------
if command -v cosign >/dev/null 2>&1; then
  info "Signing package with cosign (keyless)..."
  cosign sign-blob \
    --bundle "${PACKAGE_FILE}.bundle" \
    "${PACKAGE_FILE}" \
    && ok "Cosign bundle: ${PACKAGE_FILE}.bundle" \
    || warn "cosign signing failed — continuing without signature."
else
  warn "cosign not available — skipping package signing."
fi

# ---------------------------------------------------------------------------
# Handoff summary
# ---------------------------------------------------------------------------
echo ""
_bold "======================================================================"
_bold " Package ready for air-gap transfer"
_bold "======================================================================"
echo ""
echo "Bundled components: ${COMPONENTS}"
echo ""
echo "Files to carry across the boundary:"
echo ""
ls -lh "${PACKAGE_FILE}" "${PACKAGE_FILE}.sha256" 2>/dev/null
[[ -f "${PACKAGE_FILE}.bundle" ]] && ls -lh "${PACKAGE_FILE}.bundle"
echo ""
echo "Also transfer:"
echo "  zarf-config.yaml                (deployment defaults)"
echo "  scripts/deploy-package.sh       (deploy script)"
echo "  ccn-cis/credentials_create.yaml (Ansible secrets playbook)"
echo "  ATC/                            (Ansible DO/AS3 declarations)"
echo ""

if [[ "${INCLUDE_CERT_MANAGER}" == "false" ]]; then
  _yellow "NOTE: cert-manager was NOT bundled. To deploy cert-manager later,"
  _yellow "rebuild with --include-cert-manager and transfer the new package."
fi

_yellow "IMPORTANT: Verify the checksum on the air-gap side before deploying:"
_yellow "  sha256sum -c ${PACKAGE_FILE}.sha256"
echo ""
_green "Transfer complete. Ready for air-gap deployment."