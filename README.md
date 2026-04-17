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

---

## Avant de lancer le script

### Étape 1 — Ajouter le sous-domaine sur Cloudflare (ou ton hébergeur DNS)

Va sur **Cloudflare → ton domaine → DNS → Add record** et crée l'enregistrement suivant :

| Type | Nom | Contenu | Proxy |
|------|-----|---------|-------|
| A | `argocd` | `IP_DE_TON_VPS` | ✅ Proxied (nuage orange) |

> Si tu n'utilises pas Cloudflare, fais la même chose dans l'interface DNS de ton hébergeur (OVH, Gandi, Namecheap…).

⚠️ **Ce record DNS doit exister avant de lancer le script**, sinon ArgoCD sera installé mais inaccessible depuis l'URL.

### Étape 2 — Se connecter en root sur le VPS

```bash
ssh user@IP_DU_VPS
sudo -i
```

> Le script doit être exécuté en tant que **root**. Sans `sudo -i`, il s'arrête immédiatement.

---

## Installation

Une fois le DNS créé et la session root ouverte, lance :

```bash
curl -fsSL https://raw.githubusercontent.com/meissaniang/k3s_and_argocd_on_ubuntu/main/install.sh \
  | bash -s -- --domain argocd.mondomaine.com
```

Le script affiche à la fin l'URL, le login `admin` et le mot de passe initial.

### Options

| Option | Obligatoire | Description |
|--------|-------------|-------------|
| `--domain` | ✅ | FQDN ArgoCD (ex: `argocd.mondomaine.com`) |
| `--argocd-namespace` | ❌ | Namespace k8s (défaut: `argocd`) |
| `--k3s-version` | ❌ | Version k3s fixée (ex: `v1.29.3+k3s1`) |
| `--skip-k3s` | ❌ | Saute k3s si déjà installé |

---

## Prérequis VPS

- Ubuntu 22.04 / 24.04
- Ports **80** et **6443** ouverts dans le pare-feu
- 2 vCPU / 2 Go RAM minimum

---

## Ajouter une nouvelle app

### 1. Cloudflare — ajoute le sous-domaine

| Type | Nom | Contenu | Proxy |
|------|-----|---------|-------|
| A | `app1` | `IP_DE_TON_VPS` | ✅ Proxied |

### 2. Helm chart de l'app — ajoute un Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app1
  namespace: app1
spec:
  ingressClassName: nginx
  rules:
    - host: app1.mondomaine.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app1-svc
                port:
                  number: 80
```

> Voir aussi [`examples/app-ingress.yaml`](examples/app-ingress.yaml) comme base.

### 3. ArgoCD sync → live

ingress-nginx détecte le nouvel Ingress instantanément. Pas d'autre config nécessaire.

---

## Accès kubectl depuis ta machine locale

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
