# k3s + ArgoCD Bootstrap — VPS bare metal + Cloudflare

Installation automatique de **k3s**, **ingress-nginx**, **cert-manager** et **ArgoCD** sur un VPS Ubuntu en une seule commande `curl`.

## Comment ça fonctionne

```
Cloudflare                 VPS Ubuntu                    k3s cluster
──────────────             ───────────────────           ──────────────────────────────
*.mondomaine.com  ──DNS──► :80 / :443                    ingress-nginx (hostNetwork)
                           (bind direct, pas de LB)  ──► lit les Ingress en temps réel
                                                          ├── argocd.mondomaine.com → ArgoCD
                                                          ├── app1.mondomaine.com   → App 1
                                                          └── app2.mondomaine.com   → App 2
                                                               ↑
                                                          TLS automatique (cert-manager)
```

**Pour ajouter une nouvelle app :**
1. Tu ajoutes le sous-domaine sur Cloudflare → `app.mondomaine.com` pointe vers l'IP du VPS
2. Ton app déclare un `Ingress` avec `host: app.mondomaine.com`
3. ingress-nginx le détecte instantanément → routage actif + cert-manager émet le TLS

Tu ne touches plus au cluster pour le routage.

---

## Prérequis

| Exigence | Détail |
|----------|--------|
| OS | Ubuntu 22.04 / 24.04 |
| RAM | 2 Go min (4 Go recommandé) |
| CPU | 2 vCPU min |
| Ports ouverts | **80**, **443**, **6443** |
| DNS | Enregistrement A `*.mondomaine.com → IP du VPS` sur Cloudflare |

---

## Installation

### Option A — Cloudflare nuage gris (DNS only) ✅ le plus simple

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain argocd.mondomaine.com \
  --email  admin@mondomaine.com
```

> Sur Cloudflare : proxy **désactivé** (nuage gris ☁️) pour `*.mondomaine.com`

### Option B — Cloudflare nuage orange (proxy activé) ✅ Let's Encrypt via DNS-01

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain              argocd.mondomaine.com \
  --email               admin@mondomaine.com \
  --cloudflare-token    TON_CF_API_TOKEN \
  --cloudflare-zone-id  TON_CF_ZONE_ID
```

> Le token Cloudflare doit avoir la permission `Zone → DNS → Edit`.
> Génère-le sur : **Cloudflare Dashboard → My Profile → API Tokens → Create Token**

---

## Toutes les options

| Option | Obligatoire | Description |
|--------|-------------|-------------|
| `--domain` | ✅ | FQDN ArgoCD (ex: `argocd.mondomaine.com`) |
| `--email` | ✅ | Email Let's Encrypt |
| `--cloudflare-token` | ❌ | API token CF pour DNS-01 (proxy orange cloud) |
| `--cloudflare-zone-id` | ❌ | Zone ID Cloudflare (requis avec `--cloudflare-token`) |
| `--argocd-namespace` | ❌ | Namespace k8s ArgoCD (défaut: `argocd`) |
| `--k3s-version` | ❌ | Version k3s fixée (ex: `v1.29.3+k3s1`) |
| `--skip-k3s` | ❌ | Saute k3s si déjà installé |
| `--skip-cert-manager` | ❌ | Saute cert-manager si déjà présent |

---

## Ce qui est installé

| Composant | Rôle |
|-----------|------|
| **k3s** | Kubernetes léger (traefik + servicelb désactivés) |
| **Helm 3** | Gestionnaire de packages k8s |
| **ingress-nginx** | DaemonSet hostNetwork — bind direct :80/:443 sur le VPS |
| **cert-manager** | TLS automatique Let's Encrypt (HTTP-01 ou DNS-01 Cloudflare) |
| **ArgoCD** | GitOps CD — déploiement continu depuis Git |

---

## Ajouter une app sur le cluster

### 1. Cloudflare
Ajoute un enregistrement A : `app.mondomaine.com → IP_DU_VPS`

### 2. Ingress dans ton Helm chart / manifests

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
      secretName: mon-app-tls   # cert-manager crée ce secret automatiquement
```

### 3. ArgoCD sync → c'est live

ingress-nginx détecte le nouvel Ingress immédiatement. cert-manager émet le certificat TLS en ~30 secondes.

---

## Accès kubectl depuis ta machine

```bash
scp root@IP_VPS:/etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s
sed -i 's|https://127.0.0.1:6443|https://IP_VPS:6443|g' ~/.kube/config-k3s
export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes
```

---

## Désinstallation

```bash
/usr/local/bin/k3s-uninstall.sh
```

---

## Structure du repo

```
.
├── install.sh               ← bootstrap (curl | bash)
├── README.md
├── .gitignore
└── examples/
    ├── app-ingress.yaml     ← template Ingress pour une app
    ├── app-of-apps.yaml     ← pattern ArgoCD app-of-apps
    ├── sample-app.yaml      ← exemple Application ArgoCD
    └── values-argocd.yaml   ← valeurs Helm ArgoCD avancées
```
