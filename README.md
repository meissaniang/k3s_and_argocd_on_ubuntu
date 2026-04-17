# k3s + ArgoCD Bootstrap — VPS bare metal + Cloudflare proxy

Installation de **k3s**, **ingress-nginx** et **ArgoCD** sur un VPS Ubuntu en une seule commande `curl`.

SSL entièrement géré par Cloudflare. Le VPS ne fait que du HTTP.

## Flux

```
User ──HTTPS──► Cloudflare (SSL) ──HTTP──► VPS :80
                                            └── ingress-nginx
                                                  ├── argocd.mondomaine.com → ArgoCD
                                                  ├── app1.mondomaine.com   → App 1
                                                  └── app2.mondomaine.com   → App 2
```

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/meissaniang/k3s_and_argocd_on_ubuntu/main/install.sh \
  | bash -s -- --domain argocd.mondomaine.com
```

C'est tout. Le script affiche le mot de passe ArgoCD et l'IP du serveur à renseigner sur Cloudflare.

### Options

| Option | Obligatoire | Description |
|--------|-------------|-------------|
| `--domain` | ✅ | FQDN ArgoCD (ex: `argocd.mondomaine.com`) |
| `--argocd-namespace` | ❌ | Namespace k8s (défaut: `argocd`) |
| `--k3s-version` | ❌ | Version k3s fixée (ex: `v1.29.3+k3s1`) |
| `--skip-k3s` | ❌ | Saute k3s si déjà installé |

## Prérequis

- Ubuntu 22.04 / 24.04, accès root
- Ports **80** et **6443** ouverts
- Cloudflare : le domaine est déjà géré là-bas

## Ajouter une app

1. **Cloudflare** : ajoute `app.mondomaine.com → A → IP_VPS` (proxy ON)
2. **Helm chart** : ajoute un Ingress (voir [`examples/app-ingress.yaml`](examples/app-ingress.yaml))
3. **ArgoCD sync** → routage actif instantanément

## Accès kubectl depuis ta machine

```bash
scp root@IP_VPS:/etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s
sed -i 's|https://127.0.0.1:6443|https://IP_VPS:6443|g' ~/.kube/config-k3s
export KUBECONFIG=~/.kube/config-k3s
```

## Désinstallation

```bash
/usr/local/bin/k3s-uninstall.sh
```
