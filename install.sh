#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
#  k3s + ArgoCD Bootstrap — VPS bare metal (pas de cloud LB)
#
#  Architecture :
#    VPS (ports 80/443 directs) → ingress-nginx (hostNetwork)
#      → routing par domaine (Ingress) → services k8s
#
#  Usage :
#    curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh \
#      | bash -s -- \
#          --domain argocd.example.com \
#          --email  admin@example.com
# ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }
die()     { echo -e "\n${RED}[ERREUR]${NC} $*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────
DOMAIN=""
EMAIL=""
ARGOCD_NAMESPACE="argocd"
CERTMANAGER_NAMESPACE="cert-manager"
INGRESS_NAMESPACE="ingress-nginx"
K3S_VERSION=""
SKIP_K3S=false
SKIP_CERT_MANAGER=false

# ── Parsing des arguments ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)             DOMAIN="$2";            shift 2 ;;
    --email)              EMAIL="$2";             shift 2 ;;
    --argocd-namespace)   ARGOCD_NAMESPACE="$2";  shift 2 ;;
    --k3s-version)        K3S_VERSION="$2";       shift 2 ;;
    --skip-k3s)           SKIP_K3S=true;          shift   ;;
    --skip-cert-manager)  SKIP_CERT_MANAGER=true; shift   ;;
    *) die "Option inconnue : $1\n\nUsage: --domain FQDN --email EMAIL [--k3s-version vX.Y.Z+k3s1] [--skip-k3s] [--skip-cert-manager]" ;;
  esac
done

[[ -z "$DOMAIN" ]] && die "--domain est obligatoire  (ex: --domain argocd.example.com)"
[[ -z "$EMAIL"  ]] && die "--email est obligatoire   (ex: --email admin@example.com)"

# ── Vérifications initiales ───────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root.\n  → sudo -i  puis relance la commande"
}

check_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) : ;;
      *) warn "OS non testé : ${PRETTY_NAME:-unknown}. Poursuite..." ;;
    esac
  fi
}

check_ports() {
  for port in 80 443 6443; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      warn "Port ${port} déjà utilisé — peut causer des conflits"
    fi
  done
}

get_public_ip() {
  PUBLIC_IP=$(curl -sf --max-time 5 https://ifconfig.me \
    || curl -sf --max-time 5 https://api.ipify.org \
    || curl -sf --max-time 5 https://icanhazip.com \
    || echo "")
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "inconnue")
    warn "IP publique non détectée automatiquement, IP interne : ${PUBLIC_IP}"
  else
    info "IP publique du serveur : ${PUBLIC_IP}"
  fi
}

# ── Dépendances ───────────────────────────────────────────────────
install_deps() {
  step "Dépendances système"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl git openssl jq iproute2 ca-certificates
  success "Dépendances OK"
}

# ── k3s ───────────────────────────────────────────────────────────
install_k3s() {
  step "k3s"
  if $SKIP_K3S; then
    warn "--skip-k3s : on suppose que k3s est déjà installé"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    kubectl get nodes || die "kubectl ne répond pas — vérifie k3s"
    return
  fi

  info "Installation de k3s ${K3S_VERSION:-latest stable}..."

  # - disable traefik : on utilise ingress-nginx à la place
  # - servicelb (Klipper) désactivé aussi car on utilise hostNetwork pour nginx
  local k3s_exec="--disable=traefik --disable=servicelb"
  local install_env=""
  [[ -n "$K3S_VERSION" ]] && install_env="INSTALL_K3S_VERSION=${K3S_VERSION}"

  eval "INSTALL_K3S_EXEC='${k3s_exec}' ${install_env} bash <(curl -sfL https://get.k3s.io)"

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' > /etc/profile.d/k3s-env.sh
  chmod +x /etc/profile.d/k3s-env.sh

  info "Attente que le nœud soit Ready..."
  local i=0
  until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    sleep 5; (( i++ ))
    [[ $i -gt 36 ]] && die "k3s ne démarre pas après 3 minutes"
  done
  success "k3s opérationnel : $(kubectl get nodes --no-headers | awk '{print $1, $2}')"
}

# ── Helm ──────────────────────────────────────────────────────────
install_helm() {
  step "Helm"
  if command -v helm &>/dev/null; then
    success "Helm déjà présent : $(helm version --short)"
    return
  fi
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "Helm installé : $(helm version --short)"
}

# ── ingress-nginx (hostNetwork — pas besoin de LoadBalancer) ───────
install_nginx_ingress() {
  step "ingress-nginx (hostNetwork — bind direct 80/443 sur le VPS)"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  helm repo update >/dev/null

  # hostNetwork=true  → nginx bind directement les ports 80/443 du serveur
  # kind=DaemonSet    → tourne sur chaque nœud (idéal bare metal)
  # service.type=ClusterIP → pas de LoadBalancer cloud nécessaire
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
    --wait --timeout 5m

  success "ingress-nginx prêt — ports 80/443 bindés sur le VPS"
}

# ── cert-manager ──────────────────────────────────────────────────
install_cert_manager() {
  step "cert-manager + Let's Encrypt"
  if $SKIP_CERT_MANAGER; then
    warn "--skip-cert-manager : ignoré"
    return
  fi

  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm repo update >/dev/null

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$CERTMANAGER_NAMESPACE" \
    --create-namespace \
    --set installCRDs=true \
    --wait --timeout 5m

  info "Création des ClusterIssuers Let's Encrypt..."
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
  success "cert-manager prêt"
}

# ── ArgoCD ────────────────────────────────────────────────────────
install_argocd() {
  step "ArgoCD"

  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update >/dev/null

  helm upgrade --install argocd argo/argo-cd \
    --namespace "$ARGOCD_NAMESPACE" \
    --create-namespace \
    --set global.domain="${DOMAIN}" \
    --set server.ingress.enabled=true \
    --set server.ingress.ingressClassName=nginx \
    --set "server.ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod" \
    --set "server.ingress.annotations.nginx\.ingress\.kubernetes\.io/backend-protocol=HTTP" \
    --set "server.ingress.annotations.nginx\.ingress\.kubernetes\.io/force-ssl-redirect=true" \
    --set "server.ingress.hosts[0]=${DOMAIN}" \
    --set "server.ingress.tls[0].secretName=argocd-server-tls" \
    --set "server.ingress.tls[0].hosts[0]=${DOMAIN}" \
    --set configs.params."server\.insecure"=true \
    --wait --timeout 10m

  success "ArgoCD installé"
}

# ── Résumé final ──────────────────────────────────────────────────
print_summary() {
  step "Récupération des infos de connexion"

  local retries=0
  until kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret &>/dev/null; do
    sleep 3; (( retries++ ))
    [[ $retries -gt 20 ]] && die "Secret argocd-initial-admin-secret introuvable après 60s"
  done

  local password
  password=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║           ✅  Installation terminée !                 ║${NC}"
  echo -e "${GREEN}╠═══════════════════════════════════════════════════════╣${NC}"
  printf "${GREEN}║${NC}  %-12s ${CYAN}%-38s${NC}${GREEN}║${NC}\n" "URL :"      "https://${DOMAIN}"
  printf "${GREEN}║${NC}  %-12s ${CYAN}%-38s${NC}${GREEN}║${NC}\n" "Login :"    "admin"
  printf "${GREEN}║${NC}  %-12s ${CYAN}%-38s${NC}${GREEN}║${NC}\n" "Password :" "${password}"
  printf "${GREEN}║${NC}  %-12s ${CYAN}%-38s${NC}${GREEN}║${NC}\n" "IP serveur:" "${PUBLIC_IP}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Enregistrement DNS à créer :${NC}"
  echo -e "  ${BOLD}${DOMAIN}.  →  A  →  ${PUBLIC_IP}${NC}"
  echo ""
  echo -e "${YELLOW}Ajouter d'autres apps sur ce cluster :${NC}"
  echo -e "  → crée un Ingress avec ${BOLD}ingressClassName: nginx${NC} + annotation ${BOLD}cert-manager.io/cluster-issuer: letsencrypt-prod${NC}"
  echo -e "  → chaque domaine/sous-domaine est routé automatiquement"
  echo ""
  echo -e "${RED}⚠  Change le mot de passe ArgoCD dès ta première connexion !${NC}"
}

# ── Main ──────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║       k3s + ArgoCD Bootstrap  —  VPS bare metal       ║${NC}"
  echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
  echo ""
  info "Domaine ArgoCD   : ${DOMAIN}"
  info "Email TLS        : ${EMAIL}"
  info "Namespace ArgoCD : ${ARGOCD_NAMESPACE}"

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
