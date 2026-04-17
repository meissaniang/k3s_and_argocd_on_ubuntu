#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  k3s + ArgoCD bootstrap installer
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
#      --domain argocd.example.com \
#      --email  admin@example.com \
#      [--argocd-namespace argocd] \
#      [--k3s-version v1.29.3+k3s1] \
#      [--skip-k3s] \
#      [--skip-cert-manager]
# ─────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────
DOMAIN=""
EMAIL=""
ARGOCD_NAMESPACE="argocd"
CERTMANAGER_NAMESPACE="cert-manager"
K3S_VERSION=""          # empty = latest stable
SKIP_K3S=false
SKIP_CERT_MANAGER=false
REPO_RAW="https://raw.githubusercontent.com/YOUR_USER/k3s/main"

# ── Arg parsing ───────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)              DOMAIN="$2";               shift 2 ;;
    --email)               EMAIL="$2";                shift 2 ;;
    --argocd-namespace)    ARGOCD_NAMESPACE="$2";     shift 2 ;;
    --k3s-version)         K3S_VERSION="$2";          shift 2 ;;
    --skip-k3s)            SKIP_K3S=true;             shift   ;;
    --skip-cert-manager)   SKIP_CERT_MANAGER=true;    shift   ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -z "$DOMAIN" ]] && die "--domain est obligatoire  (ex: argocd.example.com)"
[[ -z "$EMAIL"  ]] && die "--email est obligatoire   (ex: admin@example.com)"

# ── Prereqs ───────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || die "Lance ce script en root (sudo -i puis relance)"
}

check_os() {
  . /etc/os-release 2>/dev/null || true
  case "${ID:-}" in
    ubuntu|debian) : ;;
    *) warn "OS non testé: ${PRETTY_NAME:-unknown}. Continue quand même." ;;
  esac
}

install_deps() {
  info "Installation des dépendances système..."
  apt-get update -qq
  apt-get install -y -qq curl git openssl jq
}

# ── k3s ───────────────────────────────────────
install_k3s() {
  if $SKIP_K3S; then
    warn "--skip-k3s: installation k3s ignorée"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    return
  fi

  info "Installation de k3s ${K3S_VERSION:-latest}..."
  local extra_args=""
  [[ -n "$K3S_VERSION" ]] && extra_args="INSTALL_K3S_VERSION=${K3S_VERSION}"

  curl -sfL https://get.k3s.io | eval "INSTALL_K3S_EXEC='--disable=traefik' ${extra_args} sh -"

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /etc/profile.d/k3s.sh

  info "Attente que k3s soit prêt..."
  local retries=0
  until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    sleep 5
    (( retries++ ))
    [[ $retries -gt 24 ]] && die "k3s ne démarre pas après 2 minutes"
  done
  success "k3s est opérationnel"
}

# ── Helm ──────────────────────────────────────
install_helm() {
  if command -v helm &>/dev/null; then
    success "Helm déjà installé ($(helm version --short))"
    return
  fi
  info "Installation de Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "Helm installé"
}

# ── NGINX Ingress ──────────────────────────────
install_nginx_ingress() {
  info "Installation de ingress-nginx..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
  helm repo update

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --wait --timeout 5m

  success "ingress-nginx installé"
}

# ── cert-manager ──────────────────────────────
install_cert_manager() {
  if $SKIP_CERT_MANAGER; then
    warn "--skip-cert-manager: ignoré"
    return
  fi

  info "Installation de cert-manager..."
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm repo update

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$CERTMANAGER_NAMESPACE" \
    --create-namespace \
    --set installCRDs=true \
    --wait --timeout 5m

  info "Création du ClusterIssuer Let's Encrypt..."
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
  success "cert-manager installé"
}

# ── ArgoCD ────────────────────────────────────
install_argocd() {
  info "Installation d'ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm --force-update
  helm repo update

  helm upgrade --install argocd argo/argo-cd \
    --namespace "$ARGOCD_NAMESPACE" \
    --create-namespace \
    --set server.ingress.enabled=true \
    --set server.ingress.ingressClassName=nginx \
    --set "server.ingress.hosts[0]=${DOMAIN}" \
    --set "server.ingress.tls[0].secretName=argocd-tls" \
    --set "server.ingress.tls[0].hosts[0]=${DOMAIN}" \
    --set "server.ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod" \
    --set "server.ingress.annotations.nginx\.ingress\.kubernetes\.io/ssl-passthrough=false" \
    --set "server.ingress.annotations.nginx\.ingress\.kubernetes\.io/backend-protocol=HTTP" \
    --set configs.params."server\.insecure"=true \
    --wait --timeout 10m

  success "ArgoCD installé"
}

# ── Récupération mot de passe ─────────────────
print_argocd_password() {
  info "Récupération du mot de passe ArgoCD initial..."
  local retries=0
  until kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret &>/dev/null; do
    sleep 3
    (( retries++ ))
    [[ $retries -gt 20 ]] && die "Secret ArgoCD introuvable"
  done

  local password
  password=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║          Installation terminée !                 ║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║${NC}  URL     : ${CYAN}https://${DOMAIN}${NC}"
  echo -e "${GREEN}║${NC}  Login   : ${CYAN}admin${NC}"
  echo -e "${GREEN}║${NC}  Password: ${CYAN}${password}${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}→ Change le mot de passe après ta première connexion !${NC}"
  echo -e "${YELLOW}→ DNS : pointe ${DOMAIN} vers l'IP de ce serveur${NC}"
  local node_ip
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || \
            kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  echo -e "${YELLOW}→ IP du serveur détectée : ${node_ip}${NC}"
}

# ── Main ──────────────────────────────────────
main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     k3s + ArgoCD Bootstrap Installer             ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  info "Domaine  : $DOMAIN"
  info "Email    : $EMAIL"
  info "Namespace ArgoCD : $ARGOCD_NAMESPACE"
  echo ""

  check_root
  check_os
  install_deps
  install_k3s
  install_helm
  install_nginx_ingress
  install_cert_manager
  install_argocd
  print_argocd_password
}

main
