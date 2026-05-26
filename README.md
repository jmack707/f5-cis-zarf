# F5 CIS + NGINX Air-Gap Deployment with Zarf

Air-gapped deployment of **F5 BIG-IP Container Ingress Services (CIS)**, **NGINX Plus Ingress Controller with App Protect WAF**, and **cert-manager** on a k3s cluster using [Zarf](https://github.com/defenseunicorns/zarf).

BIG-IP secrets and platform configuration (DO/AS3) are managed by Ansible and are intentionally kept out of the Zarf package. See [Run Order](#run-order) for the exact sequence.

---

## Directory Structure

```
f5-cis-zarf/
├── zarf.yaml                        # Zarf package definition
├── zarf-config.yaml                 # Default variable values (edit per environment)
├── values/
│   ├── f5-bigip-ctlr.yaml           # CIS Helm values
│   ├── nginx-ingress.yaml           # NGINX Plus IC Helm values
│   └── cert-manager.yaml            # cert-manager Helm values
├── scripts/
│   ├── create-package.sh            # Internet-side: build the .tar.zst
│   └── deploy-package.sh            # Air-gap-side: deploy to k3s
├── ccn-cis/
│   └── credentials_create.yaml      # Ansible: create bigip-login + license-token secrets
├── ATC/
│   ├── AS3/bigip1-cis.json          # AS3 declaration (virtual servers, pools)
│   └── DO/bigip1-cis.json           # Declarative Onboarding (base BIG-IP config)
└── certs/
    └── harbor-ca.crt                # Harbor self-signed CA cert (you must add this)
```

---

## Prerequisites

### Internet-connected workstation

| Tool | Purpose | Install |
|---|---|---|
| `zarf` | Package creation | [GitHub Releases](https://github.com/defenseunicorns/zarf/releases) |
| `docker` | Image pulls during create | [Docker Desktop](https://docs.docker.com/get-docker/) |
| `cosign` | Optional package signing | `brew install cosign` |
| `sha256sum` | Checksum generation | Ships with coreutils |

### Air-gapped k3s master node

| Tool | Purpose |
|---|---|
| `zarf` (same version as workstation) | Package deployment |
| `kubectl` | Cluster interaction |
| `ansible` + `kubernetes.core` | Secrets and BIG-IP config |

### Credentials you must have

| Credential | Where to get it | Used by |
|---|---|---|
| Docker Hub username/password | hub.docker.com | Pulling CIS and demo images |
| NGINX Plus JWT license file (`.jwt`) | [MyF5 / NGINX portal](https://account.f5.com/myf5) | Pulling `nginx-plus-ingress` |
| BIG-IP admin credentials | Your BIG-IP | `credentials_create.yaml` |
| Harbor admin credentials | Your Harbor instance | `deploy-package.sh` registry config |

---

## Run Order

The full workflow has three phases: **build**, **transfer**, **deploy**.

```
[Internet workstation]          [Physical transfer]       [Air-gap k3s master]
        |                              |                          |
1. Ansible credentials        ----→ carry files ----→   2. Ansible credentials
   create.yaml (optional              to air-gap              create.yaml
   if running in-band)                                         |
        |                                               3. zarf init
4. create-package.sh                                           |
        |                                               5. deploy-package.sh
        ↓                                                      |
   .tar.zst + .sha256                                  6. Ansible DO + AS3
```

**IMPORTANT:** Steps 1/2 (Ansible secrets) must complete **before** `deploy-package.sh` runs. The deploy script checks for `bigip-login` and `license-token` and will hard-fail if they don't exist.

---

## 1. Prerequisites Setup

```bash
# Install Zarf (hardcoded version avoids GitHub API rate-limiting)
# Check for newer releases at: https://github.com/defenseunicorns/zarf/releases
ZARF_VERSION="v0.75.1"

sudo curl -Lo /usr/local/bin/zarf \
  "https://github.com/defenseunicorns/zarf/releases/download/${ZARF_VERSION}/zarf_${ZARF_VERSION}_Linux_amd64"
sudo chmod +x /usr/local/bin/zarf
zarf version   # should print v0.75.1

# Download the matching init package into the current directory
curl -Lo "zarf-init-amd64-${ZARF_VERSION}.tar.zst" \
  "https://github.com/defenseunicorns/zarf/releases/download/${ZARF_VERSION}/zarf-init-amd64-${ZARF_VERSION}.tar.zst"
```

---

## 2. Internet Side: Build the Package

```bash
# Clone/copy the project to your internet-connected workstation
cd f5-cis-zarf/

# Set credentials — copy the example and fill it in
cp credentials.env.example credentials.env
chmod 600 credentials.env
$EDITOR credentials.env   # set DOCKER_USER, DOCKER_PASS, NGINX_JWT

# Optional: override component versions (or edit zarf-config.yaml)
export ZARF_CIS_VERSION="2.20.3"
export ZARF_NGINX_VERSION="5.3.2"
export ZARF_CERT_VERSION="v1.19.1"

# Make scripts executable (only needed once after cloning/unzipping)
chmod +x scripts/create-package.sh scripts/deploy-package.sh

# Build WITHOUT cert-manager (default -- smaller bundle)
# Note: create-package.sh does not need sudo
./scripts/create-package.sh

# Build WITH cert-manager bundled
./scripts/create-package.sh --include-cert-manager

# For CI (no color, non-interactive):
# Inject DOCKER_USER, DOCKER_PASS, NGINX_JWT as CI secrets/env vars
# rather than using credentials.env -- env vars take precedence.
./scripts/create-package.sh --no-color
./scripts/create-package.sh --include-cert-manager --no-color
```

The script will:
1. Log in to Docker Hub and `private-registry.nginx.com`
2. Pre-pull cert-manager images from quay.io to validate access
3. Run `zarf package create` (this pulls all images and charts into the bundle)
4. Write a `.sha256` checksum file
5. Optionally sign with cosign

**Output files** (transfer all of these):
```
zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst      ← main package (~1–3 GB)
zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst.sha256
zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst.bundle  ← cosign bundle (if signed)
zarf-init-amd64-<version>.tar.zst                          ← Zarf init package
zarf-config.yaml
scripts/deploy-package.sh
ccn-cis/credentials_create.yaml
ATC/
certs/harbor-ca.crt
```

---

## 3. Transfer: Carrying Files Across the Boundary

This step is intentionally manual. There is no automated transfer — a human carries the media.

### What to transfer

| File | Required |
|---|---|
| `zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst` | Yes |
| `zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst.sha256` | Yes |
| `zarf-init-amd64-<version>.tar.zst` | Yes (if Zarf not yet initialized) |
| `zarf` binary (matching version) | Yes (if not already on the air-gap node) |
| `zarf-config.yaml` | Yes |
| `scripts/deploy-package.sh` | Yes |
| `ccn-cis/credentials_create.yaml` | Yes |
| `ATC/` directory | Yes |
| `certs/harbor-ca.crt` | Yes |
| `zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst.bundle` | Recommended |

### Verifying integrity on arrival

```bash
# On the air-gap node, after copying files from removable media:
sha256sum -c zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst.sha256

# Expected output:
#   zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst: OK

# If cosign is available and a bundle was transferred:
cosign verify-blob \
  --bundle zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst.bundle \
  zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst
```

Do **not** proceed with deployment if the checksum does not match.

---

## 4. Air-Gap Side: Run Ansible First

Before deploying the Zarf package, the required Kubernetes secrets must exist.

```bash
# On the Ansible control node (can be the k3s master or a separate jump host
# with kubectl access to the cluster)

# 1. Edit group_vars/all/vault.yaml with your credentials, then encrypt:
ansible-vault encrypt group_vars/all/vault.yaml

# 2. Create the secrets:
ansible-playbook ccn-cis/credentials_create.yaml --ask-vault-pass

# Verify:
kubectl get secret bigip-login -n kube-system
kubectl get secret license-token -n nginx-ingress
```

---

## 5. Air-Gap Side: Deploy the Package

```bash
# On the k3s master node, as root:
cd /path/to/transferred/files/

# Edit zarf-config.yaml to match your environment (BIGIP_URL, REGISTRY_HOST, etc.)
vi zarf-config.yaml

# Deploy with defaults from zarf-config.yaml (cert-manager excluded by default)
sudo chmod +x scripts/deploy-package.sh
sudo ./scripts/deploy-package.sh --confirm

# To include cert-manager, add it to the components list in zarf-config.yaml:
#   components: "f5-cis,nginx-ingress,app-images,cert-manager"
# Or pass it directly at deploy time:
sudo ./scripts/deploy-package.sh --confirm  # after editing zarf-config.yaml

# Equivalent one-liner without editing zarf-config.yaml:
ZARF_PACKAGE_DEPLOY_COMPONENTS="f5-cis,nginx-ingress,app-images,cert-manager" \
  sudo ./scripts/deploy-package.sh --confirm

# If Zarf was already initialized (e.g., from a previous deploy):
sudo ./scripts/deploy-package.sh --skip-init --confirm
```

The deploy script will:
1. Verify the package checksum
2. Install the Harbor CA cert (system trust store + k3s containerd)
3. Write `/etc/rancher/k3s/registries.yaml` mirror configuration
4. Restart k3s to apply registry config
5. Run `zarf init` (deploys Zarf's internal registry into the cluster)
6. Run `zarf package deploy`
7. Print a post-deploy summary

---

## 6. Post-Deploy: BIG-IP Configuration via Ansible

```bash
# Apply Declarative Onboarding (base BIG-IP platform config):
# Edit ATC/DO/bigip1-cis.json to match your BIG-IP network topology first.
ansible-playbook ATC/DO/site.yaml --ask-vault-pass    # adjust playbook name to yours

# Apply AS3 declaration (virtual servers and pools):
# Edit ATC/AS3/bigip1-cis.json to match your VIP addresses.
ansible-playbook ATC/AS3/site.yaml --ask-vault-pass
```

---

## 7. Validation

### CIS is managing BIG-IP

```bash
# Watch CIS logs for successful POST to BIG-IP (AS3 declaration pushes)
kubectl logs -n kube-system deploy/f5-bigip-ctlr -f | grep -E "POST|Error|partition"

# Check CIS has connected to BIG-IP
kubectl logs -n kube-system deploy/f5-bigip-ctlr | grep "Connected to BIG-IP"

# Verify CIS VirtualServer CRDs are registered
kubectl get crd | grep virtual

# Create a test VirtualServer CR and confirm CIS pushes it to BIG-IP:
kubectl apply -f - <<'EOF'
apiVersion: "cis.f5.com/v1"
kind: VirtualServer
metadata:
  name: test-vs
  namespace: default
  labels:
    f5cr: "true"
spec:
  virtualServerAddress: "10.1.10.101"
  host: test.lab.test.local
  pools:
    - path: /
      service: nginx-hello-svc
      servicePort: 80
EOF
```

### NGINX Plus IC

```bash
# Check IC is Ready
kubectl get pods -n nginx-ingress

# Verify IngressClass
kubectl get ingressclass nginx

# Check App Protect WAF is enabled
kubectl logs -n nginx-ingress deploy/nginx-ingress | grep "AppProtect"

# View NGINX Plus dashboard (forward port locally)
kubectl port-forward -n nginx-ingress svc/nginx-ingress 8080:8080
# Open: http://localhost:8080/dashboard.html
```

### cert-manager (if deployed)

```bash
# Verify cert-manager components
kubectl get pods -n cert-manager

# Check ClusterIssuer was created
kubectl get clusterissuer

# Test certificate issuance
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-cert-tls
  issuerRef:
    name: lab-self-signed
    kind: ClusterIssuer
  commonName: test.lab.test.local
  dnsNames:
    - test.lab.test.local
EOF

kubectl describe certificate test-cert -n default
kubectl get secret test-cert-tls -n default
```

---

## 8. Updating: Creating and Deploying a New Package Version

When a component version changes (e.g., upgrading CIS from 2.20.3 to 2.20.4):

### On the internet workstation

```bash
# Update version variables
export ZARF_CIS_VERSION="2.20.4"

# Re-run the create script — match the --include-cert-manager flag to your original build.
# If your running cluster was deployed with cert-manager, include it here too.
./scripts/create-package.sh
# or, if cert-manager was included in the original package:
./scripts/create-package.sh --include-cert-manager

# The output filename will still be:
#   zarf-package-f5-cis-nginx-stack-amd64-1.0.0.tar.zst
# (version comes from zarf.yaml metadata.version — bump that for major changes)
```

To bump the package version, edit `zarf.yaml`:

```yaml
metadata:
  version: 1.1.0   # Increment for component upgrades
```

### On the air-gap node

```bash
# Update zarf-config.yaml to reflect the new version
vi zarf-config.yaml  # set CIS_VERSION: "2.20.4"

# Deploy the new package — Zarf will upgrade in-place via Helm upgrade
sudo ./scripts/deploy-package.sh --confirm --skip-init  # skip-init if Zarf is already up

# Verify rolling update
kubectl rollout status deployment/f5-bigip-ctlr -n kube-system
```

### Partial updates (single component)

```bash
# Deploy only the f5-cis component from an updated package:
zarf package deploy zarf-package-f5-cis-nginx-stack-amd64-1.1.0.tar.zst \
  --components f5-cis \
  --confirm
```

---

## Troubleshooting

### CIS stuck in CrashLoopBackOff

```bash
kubectl logs -n kube-system deploy/f5-bigip-ctlr --previous
# Common causes:
# - bigip-login secret missing or has wrong credentials
# - BIG-IP unreachable from cluster nodes
# - The 'k8s' partition does not exist on BIG-IP (DO must run first)
```

### NGINX Plus pod in ImagePullBackOff

```bash
kubectl describe pod -n nginx-ingress
# Common causes:
# - license-token imagePullSecret missing
# - Harbor registry not reachable (check registries.yaml and k3s restart)
# - CA cert not trusted by containerd (check /etc/rancher/k3s/certs.d/)
```

### Zarf internal registry connectivity

```bash
# Check Zarf's registry pod is running
kubectl get pods -n zarf

# Inspect registry pod logs
kubectl logs -n zarf -l app=zarf-docker-registry
```

### k3s registry mirror not working

```bash
# Validate config syntax
cat /etc/rancher/k3s/registries.yaml

# Check k3s service logs for mirror errors
journalctl -u k3s -f | grep -i "mirror\|registry\|harbor"

# Verify CA cert is trusted
curl -v --cacert /etc/rancher/k3s/certs.d/harbor.test.local/harbor-ca.crt \
  https://harbor.test.local/v2/
```

---

## Scope: What Zarf Manages vs. What Ansible Manages

| Responsibility | Managed by |
|---|---|
| Container images (pull, bundle, push to internal registry) | **Zarf** |
| Helm chart lifecycle (install, upgrade) | **Zarf** |
| Kubernetes secrets (`bigip-login`, `license-token`) | **Ansible** |
| BIG-IP base platform config (DO) | **Ansible** |
| BIG-IP virtual servers + pools (AS3) | **Ansible** |
| k3s registry mirror config (`registries.yaml`) | `deploy-package.sh` |
| Harbor CA trust | `deploy-package.sh` |
