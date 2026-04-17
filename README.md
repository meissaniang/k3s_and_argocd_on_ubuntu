# k3s + ArgoCD Bootstrap — VPS bare metal + Cloudflare proxy

Installation automatique de **k3s**, **ingress-nginx**, **cert-manager** et **ArgoCD** sur un VPS Ubuntu en une seule commande `curl`.

**Conçu pour :** domaine partagé entre plusieurs VPS, Cloudflare proxy toujours ON, sous-domaines ajoutés manuellement par VPS.

## Comment ça fonctionne

```
Cloudflare (proxy ON)      VPS Ubuntu                  k3s
──────────────────────     ─────────────────────       ──────────────────────────────
argocd.mondomaine.com  ──► :80/:443                    ingress-nginx (hostNetwork)
app1.mondomaine.com    ──► (bind direct sur le VPS) ──► routing par Host header
app2.mondomaine.com    ──►                              ├── argocd.mondomaine.com → ArgoCD
                                                        ├── app1.mondomaine.com   → App 1
                                                        └── app2.mondomaine.com   → App 2
                                                             ↑
                                                        TLS via DNS-01 Cloudflare API
                                                        (fonctionne même proxy ON)
```

**Workflow par app :**
1. Tu ajoutes le sous-domaine sur Cloudflare → `app.mondomaine.com → IP_DE_CE_VPS` (proxy ON)
2. Ton app déclare un `Ingress` avec `host: app.mondomaine.com`
3. ArgoCD sync → ingress-nginx route automatiquement → cert-manager émet le TLS

---

## Prérequis

| Exigence | Détail |
|----------|--------|
| OS | Ubuntu 22.04 / 24.04 |
| RAM | 2 Go min (4 Go recommandé) |
| CPU | 2 vCPU min |
| Ports ouverts | **80**, **443**, **6443** |
| Cloudflare | API Token avec permission **Zone → DNS → Edit** |

### Créer le token Cloudflare

1. Dashboard Cloudflare → **My Profile → API Tokens → Create Token**
2. Template : **Edit zone DNS**
3. Zone Resources : **Include → Specific zone → mondomaine.com**
4. Copie le token généré

Le Zone ID se trouve dans le dashboard Cloudflare, colonne de droite de la page principale du domaine.

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain             argocd.mondomaine.com \
  --email              admin@mondomaine.com  \
  --cloudflare-token   TON_CF_API_TOKEN      \
  --cloudflare-zone-id TON_CF_ZONE_ID
```

Après l'installation, le script affiche :
- L'URL ArgoCD + login + mot de passe initial
- L'enregistrement DNS A à créer sur Cloudflare pour ce VPS

### Options

| Option | Obligatoire | Description |
|--------|-------------|-------------|
| `--domain` | ✅ | FQDN ArgoCD (ex: `argocd.mondomaine.com`) |
| `--email` | ✅ | Email Let's Encrypt |
| `--cloudflare-token` | ✅ | API token Cloudflare (Zone DNS Edit) |
| `--cloudflare-zone-id` | ✅ | Zone ID Cloudflare du domaine |
| `--argocd-namespace` | ❌ | Namespace k8s (défaut: `argocd`) |
| `--k3s-version` | ❌ | Version k3s fixée (ex: `v1.29.3+k3s1`) |
| `--skip-k3s` | ❌ | Saute k3s si déjà installé |
| `--skip-cert-manager` | ❌ | Saute cert-manager si déjà présent |

---

## Ce qui est installé

| Composant | Rôle |
|-----------|------|
| **k3s** | Kubernetes léger (traefik + servicelb désactivés) |
| **Helm 3** | Gestionnaire de packages k8s |
| **ingress-nginx** | DaemonSet hostNetwork — bind direct :80/:443, pas de LoadBalancer |
| **cert-manager** | TLS Let's Encrypt via DNS-01 Cloudflare (proxy ON compatible) |
| **ArgoCD** | GitOps CD |

---

## Ajouter une app sur le cluster

### 1. Cloudflare
Ajoute un enregistrement A manuel :
```
app.mondomaine.com  →  A  →  IP_DE_CE_VPS  (proxy : ON ✅)
```

### 2. Ingress dans ton Helm chart

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

### 3. ArgoCD sync → live

ingress-nginx détecte le nouvel Ingress instantanément. cert-manager émet le certificat via l'API Cloudflare DNS (sans passer par HTTP).

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

## Structure

```
.
├── install.sh               ← bootstrap (curl | bash)
├── README.md
├── .gitignore
└── examples/
    ├── app-ingress.yaml     ← template Ingress à copier par app
    ├── app-of-apps.yaml     ← pattern ArgoCD app-of-apps
    ├── sample-app.yaml      ← exemple Application ArgoCD
    └── values-argocd.yaml   ← valeurs Helm ArgoCD avancées
```
