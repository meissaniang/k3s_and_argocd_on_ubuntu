# k3s + ArgoCD Bootstrap — VPS bare metal

Installation automatique de **k3s**, **ingress-nginx**, **cert-manager** (Let's Encrypt) et **ArgoCD** sur un VPS Ubuntu — en une seule commande `curl`.

Pas besoin de cloud LoadBalancer : ingress-nginx tourne en **hostNetwork** et bind directement les ports 80/443 du serveur. Chaque domaine/sous-domaine est routé par le contrôleur Ingress.

## Prérequis

| Exigence | Détail |
|----------|--------|
| OS | Ubuntu 22.04 ou 24.04 |
| RAM | 2 Go minimum (4 Go recommandé) |
| CPU | 2 vCPU minimum |
| Accès | root (`sudo -i`) |
| Ports ouverts | **80**, **443**, **6443** |
| DNS | Le domaine pointe déjà vers l'IP du VPS |

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain argocd.example.com \
  --email   admin@example.com
```

Le script affiche à la fin l'URL, le login `admin` et le mot de passe initial.

### Toutes les options

| Option | Obligatoire | Défaut | Description |
|--------|-------------|--------|-------------|
| `--domain` | ✅ | — | FQDN ArgoCD (ex: `argocd.monsite.com`) |
| `--email` | ✅ | — | Email pour les certificats Let's Encrypt |
| `--argocd-namespace` | ❌ | `argocd` | Namespace Kubernetes d'ArgoCD |
| `--k3s-version` | ❌ | latest | Version précise (ex: `v1.29.3+k3s1`) |
| `--skip-k3s` | ❌ | — | Saute k3s si déjà installé |
| `--skip-cert-manager` | ❌ | — | Saute cert-manager si déjà présent |

### Exemples

Avec version k3s fixée :
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain argocd.mondomaine.com \
  --email  devops@mondomaine.com \
  --k3s-version v1.29.3+k3s1
```

Sur un cluster k3s existant :
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain argocd.mondomaine.com \
  --email  devops@mondomaine.com \
  --skip-k3s
```

## Architecture

```
                        Internet
                           │
                    ┌──────▼──────┐
                    │  VPS Ubuntu  │  ← ports 80/443 directs (pas de LB cloud)
                    └──────┬──────┘
                           │
              ┌────────────▼────────────┐
              │  ingress-nginx           │  hostNetwork=true
              │  (DaemonSet)             │  bind 80/443 sur le host
              └────────────┬────────────┘
                           │  routing par Host header (domaine)
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
   argocd.dom.com    app1.dom.com     app2.dom.com
   (ArgoCD UI)       (ton app 1)      (ton app 2)
          │
          ▼
   cert-manager → Let's Encrypt TLS automatique
```

## Ce qui est installé

| Composant | Rôle |
|-----------|------|
| **k3s** | Kubernetes léger (traefik et servicelb désactivés) |
| **Helm 3** | Gestionnaire de packages Kubernetes |
| **ingress-nginx** | Reverse proxy + routage par domaine (hostNetwork) |
| **cert-manager** | Certificats TLS automatiques via Let's Encrypt |
| **ArgoCD** | GitOps — déploiement continu depuis Git |

## Ajouter une application sur le cluster

Chaque nouvelle app déployée sur ce cluster n'a besoin que d'un **Ingress** :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mon-app
  namespace: mon-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: app.mondomaine.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mon-app-svc
                port:
                  number: 80
  tls:
    - hosts:
        - app.mondomaine.com
      secretName: mon-app-tls
```

Le certificat TLS est émis automatiquement par cert-manager. Pas d'autre config nécessaire.

## Accès kubectl depuis ta machine locale

```bash
# Copier le kubeconfig
scp root@<IP_VPS>:/etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s

# Remplacer l'IP locale par l'IP publique du VPS
sed -i 's|https://127.0.0.1:6443|https://<IP_VPS>:6443|g' ~/.kube/config-k3s

export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes
```

## Désinstallation complète

```bash
/usr/local/bin/k3s-uninstall.sh
```

## Structure du repo

```
.
├── install.sh                   ← script bootstrap (curl | bash)
├── README.md
├── .gitignore
└── examples/
    ├── app-ingress.yaml         ← template Ingress pour une app
    ├── app-of-apps.yaml         ← pattern ArgoCD app-of-apps
    ├── sample-app.yaml          ← exemple Application ArgoCD
    └── values-argocd.yaml       ← valeurs Helm ArgoCD avancées
```
