#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  k3s + ArgoCD Bootstrap — VPS bare metal
#
#  Flux : Cloudflare DNS ──► VPS :80/:443 (ingress-nginx hostNetwork)
#           ──► routing automatique par sous-domaine (Ingress k8s)
#           ──► TLS automatique (cert-manager + Let's Encrypt)
#
#  Usage minimal :
#    curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh \
#      | bash -s -- --domain argocd.example.com --email admin@example.com
#
#  Avec proxy Cloudflare (nuage orange) :
#    ... | bash -s -- --domain argocd.example.com --email admin@example.com \
#            --cloudflare-token TON_CF_API_TOKEN --cloudflare-zone-id TON_ZONE_ID
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }
die()     { echo -e "\n${RED}[ERREUR]${NC} $*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
DOMAIN=""
EMAIL=""
ARGOCD_NAMESPACE="argocd"
CERTMANAGER_NAMESPACE="cert-manager"
INGRESS_NAMESPACE="ingress-nginx"
K3S_VERSION=""
SKIP_K3S=false
SKIP_CERT_MANAGER=false
# Cloudflare DNS-01 (pour proxy orange cloud)
CF_API_TOKEN=""
CF_ZONE_ID=""

# ── Arguments ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)              DOMAIN="$2";            shift 2 ;;
    --email)               EMAIL="$2";             shift 2 ;;
    --argocd-namespace)    ARGOCD_NAMESPACE="$2";  shift 2 ;;
    --k3s-version)         K3S_VERSION="$2";       shift 2 ;;
    --skip-k3s)            SKIP_K3S=true;          shift   ;;
    --skip-cert-manager)   SKIP_CERT_MANAGER=true; shift   ;;
    --cloudflare-token)    CF_API_TOKEN="$2";      shift 2 ;;
    --cloudflare-zone-id)  CF_ZONE_ID="$2";        shift 2 ;;
    *) die "Option inconnue : $1\nUsage: --domain FQDN --email EMAIL [options]" ;;
  esac
done

[[ -z "$DOMAIN" ]] && die "--domain obligatoire  (ex: argocd.example.com)"
[[ -z "$EMAIL"  ]] && die "--email obligatoire   (ex: admin@example.com)"

# Mode de validation TLS
if [[ -n "$CF_API_TOKEN" ]]; then
  TLS_MODE="cloudflare-dns01"
  [[ -z "$CF_ZONE_ID" ]] && die "--cloudflare-zone-id obligatoire avec --cloudflare-token"
  info "Mode TLS : DNS-01 via Cloudflare API (compatible proxy orange cloud)"
else
  TLS_MODE="http01"
  info "Mode TLS : HTTP-01 standard (Cloudflare en DNS only / nuage gris requis)"
fi

# Domaine racine (ex: "argocd.example.com" → "example.com")
ROOT_DOMAIN="${DOMAIN#*.}"

# ── Vérifications ─────────────────────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || die "Doit être exécuté en root (sudo -i)"
}

check_os() {
  [[ -f /etc/os-release ]] && . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) : ;;
    *) warn "OS non testé : ${PRETTY_NAME:-unknown}" ;;
  esac
}

check_ports() {
  for port in 80 443 6443; do
    ss -tlnp 2>/dev/null | grep -q ":${port} " \
      && warn "Port ${port} déjà utilisé — risque de conflit"
  done
}

get_public_ip() {
  PUBLIC_IP=$(
    curl -sf --max-time 5 https://ifconfig.me ||
    curl -sf --max-time 5 https://api.ipify.org ||
    curl -sf --max-time 5 https://icanhazip.com ||
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' ||
    echo ""
  )
  [[ -z "$PUBLIC_IP" ]] && warn "IP publique non détectée" || info "IP publique : ${PUBLIC_IP}"
}

# ── Dépendances ───────────────────────────────────────────────────────────────
install_deps() {
  step "Dépendances"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl git openssl jq iproute2 ca-certificates
  success "OK"
}

# ── k3s ───────────────────────────────────────────────────────────────────────
install_k3s() {
  step "k3s"

  if $SKIP_K3S; then
    warn "--skip-k3s : k3s supposé déjà installé"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    kubectl get nodes &>/dev/null || die "kubectl ne répond pas"
    return
  fi

  info "Installation k3s ${K3S_VERSION:-latest}..."
  local env_vars="INSTALL_K3S_EXEC='--disable=traefik --disable=servicelb'"
  [[ -n "$K3S_VERSION" ]] && env_vars="${env_vars} INSTALL_K3S_VERSION=${K3S_VERSION}"
  eval "${env_vars} bash <(curl -sfL https://get.k3s.io)"

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' > /etc/profile.d/k3s-env.sh

  info "Attente nœud Ready..."
  local i=0
  until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    sleep 5; (( i++ ))
    [[ $i -gt 36 ]] && die "k3s pas Ready après 3 min"
  done
  success "$(kubectl get nodes --no-headers | awk '{print $1, $2}')"
}

# ── Helm ──────────────────────────────────────────────────────────────────────
install_helm() {
  step "Helm"
  command -v helm &>/dev/null \
    && { success "Déjà installé : $(helm version --short)"; return; }
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "$(helm version --short)"
}

# ── ingress-nginx ─────────────────────────────────────────────────────────────
# hostNetwork=true  → bind direct sur les ports 80/443 du VPS
# DaemonSet         → tourne sur chaque nœud
# service=ClusterIP → aucun LoadBalancer cloud nécessaire
# ingressClass=default → récupère automatiquement tout Ingress sans classe explicite
install_nginx_ingress() {
  step "ingress-nginx (hostNetwork — bind direct :80/:443)"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  helm repo update >/dev/null

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "$INGRESS_NAMESPACE" \
    --create-namespace \
    --set controller.kind=DaemonSet \
    --set controller.hostNetwork=true \
    --set controller.hostPort.enabled=true \
    --set controller.hostPort.ports.http=80 \
    --set controller.hostPort.ports.https=443 \
    --set controller.service.type=ClusterIP \
    --set controller.dnsPolicy=ClusterFirstWithHostNet \
    --set controller.ingressClassResource.default=true \
    --set controller.ingressClassResource.name=nginx \
    --wait --timeout 5m

  success "ingress-nginx prêt — ports 80/443 bindés sur le VPS"
}

# ── cert-manager ──────────────────────────────────────────────────────────────
install_cert_manager() {
  step "cert-manager"
  $SKIP_CERT_MANAGER && { warn "--skip-cert-manager ignoré"; return; }

  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm repo update >/dev/null

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$CERTMANAGER_NAMESPACE" \
    --create-namespace \
    --set installCRDs=true \
    --wait --timeout 5m

  if [[ "$TLS_MODE" == "cloudflare-dns01" ]]; then
    _setup_clusterissuer_dns01
  else
    _setup_clusterissuer_http01
  fi

  success "cert-manager prêt"
}

# HTTP-01 : Cloudflare en DNS only (nuage gris)
_setup_clusterissuer_http01() {
  info "ClusterIssuer : Let's Encrypt HTTP-01 (DNS only / nuage gris)"
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
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
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
      name: letsencrypt-staging
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
}

# DNS-01 via Cloudflare API : compatible proxy orange cloud
_setup_clusterissuer_dns01() {
  info "ClusterIssuer : Let's Encrypt DNS-01 via Cloudflare (nuage orange OK)"

  # Stocke le token CF dans un secret Kubernetes
  kubectl create namespace "$CERTMANAGER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic cloudflare-api-token \
    --namespace "$CERTMANAGER_NAMESPACE" \
    --from-literal=api-token="${CF_API_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

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
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
        selector:
          dnsZones:
            - "${ROOT_DOMAIN}"
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
      name: letsencrypt-staging
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
        selector:
          dnsZones:
            - "${ROOT_DOMAIN}"
EOF
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────
install_argocd() {
  step "ArgoCD"

  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update >/dev/null

  helm upgrade --install argocd argo/argo-cd \
    --namespace "$ARGOCD_NAMESPACE" \
    --create-namespace \
    --set global.domain="${DOMAIN}" \
    --set configs.params."server\.insecure"=true \
    --set server.ingress.enabled=true \
    --set server.ingress.ingressClassName=nginx \
    --set "server.ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod" \
    --set "server.ingress.annotations.nginx\.ingress\.kubernetes\.io/backend-protocol=HTTP" \
    --set "server.ingress.annotations.nginx\.ingress\.kubernetes\.io/force-ssl-redirect=true" \
    --set "server.ingress.hosts[0]=${DOMAIN}" \
    --set "server.ingress.tls[0].secretName=argocd-server-tls" \
    --set "server.ingress.tls[0].hosts[0]=${DOMAIN}" \
    --wait --timeout 10m

  success "ArgoCD installé sur https://${DOMAIN}"
}

# ── Résumé ────────────────────────────────────────────────────────────────────
print_summary() {
  step "Récupération mot de passe ArgoCD"

  local i=0
  until kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret &>/dev/null; do
    sleep 3; (( i++ ))
    [[ $i -gt 20 ]] && die "Secret argocd-initial-admin-secret introuvable"
  done

  local pass
  pass=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║            ✅  Installation terminée !                   ║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
  printf  "${GREEN}║${NC}  %-14s ${CYAN}%-40s${NC}${GREEN}║${NC}\n" "URL :"       "https://${DOMAIN}"
  printf  "${GREEN}║${NC}  %-14s ${CYAN}%-40s${NC}${GREEN}║${NC}\n" "Login :"     "admin"
  printf  "${GREEN}║${NC}  %-14s ${CYAN}%-40s${NC}${GREEN}║${NC}\n" "Mot de passe:" "${pass}"
  printf  "${GREEN}║${NC}  %-14s ${CYAN}%-40s${NC}${GREEN}║${NC}\n" "IP serveur :" "${PUBLIC_IP:-inconnue}"
  printf  "${GREEN}║${NC}  %-14s ${CYAN}%-40s${NC}${GREEN}║${NC}\n" "Mode TLS :"  "${TLS_MODE}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

  echo ""
  echo -e "${BOLD}Cloudflare — enregistrement DNS à créer :${NC}"
  if [[ "$TLS_MODE" == "cloudflare-dns01" ]]; then
    echo -e "  Type A  |  ${BOLD}*.${ROOT_DOMAIN}${NC}  →  ${PUBLIC_IP}   (proxy: ✅ orange cloud OK)"
    echo -e "  Type A  |  ${BOLD}${ROOT_DOMAIN}${NC}      →  ${PUBLIC_IP}   (proxy: ✅ orange cloud OK)"
  else
    echo -e "  Type A  |  ${BOLD}*.${ROOT_DOMAIN}${NC}  →  ${PUBLIC_IP}   (proxy: ⚠️  DNS only / nuage gris)"
    echo -e "  Type A  |  ${BOLD}${ROOT_DOMAIN}${NC}      →  ${PUBLIC_IP}   (proxy: ⚠️  DNS only / nuage gris)"
  fi

  echo ""
  echo -e "${BOLD}Déployer une nouvelle app :${NC}"
  echo -e "  1. Ajoute le sous-domaine sur Cloudflare  →  ${PUBLIC_IP}"
  echo -e "  2. Dans ton Helm chart / manifests, ajoute un Ingress avec :"
  echo -e "     ${CYAN}host: monapp.${ROOT_DOMAIN}${NC}"
  echo -e "     ${CYAN}annotation: cert-manager.io/cluster-issuer: letsencrypt-prod${NC}"
  echo -e "  3. ArgoCD sync → ingress-nginx route instantanément → TLS automatique"
  echo ""
  echo -e "${RED}⚠  Change le mot de passe après ta première connexion !${NC}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║    k3s + ArgoCD Bootstrap — VPS bare metal + Cloudflare  ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  info "Domaine ArgoCD : ${DOMAIN}"
  info "Email TLS      : ${EMAIL}"
  info "Mode TLS       : ${TLS_MODE}"

  check_root
  check_os
  check_ports
  get_public_ip
  install_deps
  install_k3s
  install_helm
  install_nginx_ingress
  install_cert_manager
  install_argocd
  print_summary
}

main
