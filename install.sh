#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  k3s + ArgoCD Bootstrap — VPS bare metal + Cloudflare proxy
#
#  SSL géré par Cloudflare. Le VPS ne fait que du HTTP.
#
#  Flux :
#    User ──HTTPS──► Cloudflare (SSL) ──HTTP──► VPS :80
#      ──► ingress-nginx (hostNetwork) ──► routing par sous-domaine
#
#  Usage :
#    curl -fsSL https://raw.githubusercontent.com/meissaniang/k3s_and_argocd_on_ubuntu/main/install.sh \
#      | bash -s -- --domain argocd.mondomaine.com
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
ARGOCD_NAMESPACE="argocd"
INGRESS_NAMESPACE="ingress-nginx"
K3S_VERSION=""
SKIP_K3S=false

# ── Arguments ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)            DOMAIN="$2";            shift 2 ;;
    --argocd-namespace)  ARGOCD_NAMESPACE="$2";  shift 2 ;;
    --k3s-version)       K3S_VERSION="$2";       shift 2 ;;
    --skip-k3s)          SKIP_K3S=true;          shift   ;;
    *) die "Option inconnue : $1\nUsage : --domain argocd.mondomaine.com [--k3s-version vX.Y.Z+k3s1] [--skip-k3s]" ;;
  esac
done

[[ -z "$DOMAIN" ]] && die "--domain obligatoire  (ex: argocd.mondomaine.com)"

# ── Checks ────────────────────────────────────────────────────────────────────
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
  for port in 80 6443; do
    ss -tlnp 2>/dev/null | grep -q ":${port} " && warn "Port ${port} déjà utilisé"
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
  [[ -z "$PUBLIC_IP" ]] \
    && warn "IP publique non détectée" \
    || info "IP publique : ${PUBLIC_IP}"
}

# ── Dépendances ───────────────────────────────────────────────────────────────
install_deps() {
  step "Dépendances"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl git jq iproute2 ca-certificates
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
  [[ -n "$K3S_VERSION" ]] && env_vars="INSTALL_K3S_VERSION=${K3S_VERSION} ${env_vars}"
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
# hostNetwork=true → bind direct :80 sur le VPS, pas de LoadBalancer
# DaemonSet        → tourne sur chaque nœud
# service=ClusterIP → pas de cloud LB nécessaire
install_nginx_ingress() {
  step "ingress-nginx (hostNetwork — bind direct :80)"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  helm repo update >/dev/null

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "$INGRESS_NAMESPACE" \
    --create-namespace \
    --set controller.kind=DaemonSet \
    --set controller.hostNetwork=true \
    --set controller.hostPort.enabled=true \
    --set controller.hostPort.ports.http=80 \
    --set controller.service.type=ClusterIP \
    --set controller.dnsPolicy=ClusterFirstWithHostNet \
    --set controller.ingressClassResource.default=true \
    --set controller.ingressClassResource.name=nginx \
    --wait --timeout 5m

  success "ingress-nginx prêt — port 80 bindé sur le VPS"
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
    --set "server.ingress.hosts[0]=${DOMAIN}" \
    --wait --timeout 10m

  success "ArgoCD installé"
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
  printf  "${GREEN}║${NC}  %-16s ${CYAN}%-38s${NC}${GREEN}║${NC}\n" "URL :"          "https://${DOMAIN}"
  printf  "${GREEN}║${NC}  %-16s ${CYAN}%-38s${NC}${GREEN}║${NC}\n" "Login :"        "admin"
  printf  "${GREEN}║${NC}  %-16s ${CYAN}%-38s${NC}${GREEN}║${NC}\n" "Mot de passe :" "${pass}"
  printf  "${GREEN}║${NC}  %-16s ${CYAN}%-38s${NC}${GREEN}║${NC}\n" "IP serveur :"   "${PUBLIC_IP:-inconnue}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}Cloudflare — enregistrement DNS à créer :${NC}"
  echo -e "  A  |  ${BOLD}${DOMAIN}${NC}  →  ${PUBLIC_IP}  |  Proxy ON ✅"
  echo ""
  echo -e "${BOLD}Pour chaque nouvelle app :${NC}"
  echo -e "  1. Ajoute sur Cloudflare : ${BOLD}app.mondomaine.com${NC} → ${PUBLIC_IP}  (proxy ON)"
  echo -e "  2. Dans ton Helm chart, déclare un Ingress (voir examples/app-ingress.yaml)"
  echo -e "  3. ArgoCD sync → routage actif instantanément"
  echo ""
  echo -e "${RED}⚠  Change le mot de passe ArgoCD après ta première connexion !${NC}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║   k3s + ArgoCD Bootstrap — bare metal + Cloudflare proxy ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  info "Domaine ArgoCD : ${DOMAIN}"
  info "SSL            : géré par Cloudflare (HTTP uniquement côté VPS)"

  check_root
  check_os
  check_ports
  get_public_ip
  install_deps
  install_k3s
  install_helm
  install_nginx_ingress
  install_argocd
  print_summary
}

main
