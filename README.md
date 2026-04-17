# k3s + ArgoCD Bootstrap

Installation automatique de **k3s**, **Helm**, **ingress-nginx**, **cert-manager** (Let's Encrypt) et **ArgoCD** sur un VPS Ubuntu — en une seule commande `curl`.

## Prérequis

- VPS Ubuntu 22.04 / 24.04 (minimum 2 vCPU, 4 Go RAM)
- Accès root (`sudo -i`)
- Le DNS du domaine souhaité pointe déjà vers l'IP du VPS
- Ports ouverts : `80`, `443`, `6443`

## Installation rapide

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain argocd.example.com \
  --email   admin@example.com
```

### Options disponibles

| Option | Obligatoire | Description |
|--------|-------------|-------------|
| `--domain` | ✅ | FQDN pour l'UI ArgoCD (ex: `argocd.monsite.com`) |
| `--email` | ✅ | Email Let's Encrypt pour les certificats TLS |
| `--argocd-namespace` | ❌ | Namespace ArgoCD (défaut: `argocd`) |
| `--k3s-version` | ❌ | Version k3s précise (ex: `v1.29.3+k3s1`) |
| `--skip-k3s` | ❌ | Saute l'installation k3s (si déjà installé) |
| `--skip-cert-manager` | ❌ | Saute cert-manager (si déjà présent) |

### Exemples

Installation complète avec version k3s fixée :
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain   argocd.mondomaine.com \
  --email    devops@mondomaine.com \
  --k3s-version v1.29.3+k3s1
```

Sur un cluster k3s existant (skip k3s) :
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/k3s/main/install.sh | bash -s -- \
  --domain argocd.mondomaine.com \
  --email  devops@mondomaine.com \
  --skip-k3s
```

## Ce qui est installé

```
Ubuntu VPS
└── k3s (Kubernetes léger)
    ├── ingress-nginx       → reverse proxy + LoadBalancer
    ├── cert-manager        → TLS automatique via Let's Encrypt
    │   └── ClusterIssuer   → letsencrypt-prod + letsencrypt-staging
    └── ArgoCD              → GitOps CD
        └── Ingress TLS     → https://<domain>
```

## Après l'installation

1. **Connecte-toi** sur `https://<domain>` avec `admin` / `<mot de passe affiché>`
2. **Change le mot de passe** dans Settings → Account → Update Password
3. **Ajoute ton repo Git** dans Settings → Repositories
4. **Crée une Application ArgoCD** pointant vers ton Helm chart ou manifests

## Accès kubectl depuis ta machine locale

```bash
# Copie le kubeconfig depuis le VPS
scp root@<IP_VPS>:/etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s

# Remplace 127.0.0.1 par l'IP publique du VPS
sed -i 's/127.0.0.1/<IP_VPS>/g' ~/.kube/config-k3s

export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes
```

## Désinstallation

```bash
# Désinstaller k3s
/usr/local/bin/k3s-uninstall.sh

# Nettoyer Helm (optionnel, fait automatiquement par k3s-uninstall)
helm uninstall argocd -n argocd
helm uninstall cert-manager -n cert-manager
helm uninstall ingress-nginx -n ingress-nginx
```

## Structure du repo

```
.
├── install.sh          ← script principal (curl | bash)
├── README.md
├── .gitignore
└── examples/
    ├── app-of-apps.yaml        ← pattern ArgoCD app-of-apps
    ├── sample-app.yaml         ← exemple d'Application ArgoCD
    └── values-argocd.yaml      ← valeurs Helm ArgoCD avancées
```
