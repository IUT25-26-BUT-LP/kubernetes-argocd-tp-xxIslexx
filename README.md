# Défi 4 — Pipeline DevSecOps avec Kubernetes, ArgoCD et Trivy

Mise en place d'une chaîne CI/CD sécurisée combinant **GitHub Actions**, un cluster **Kubernetes** local (Kind), un déploiement continu via **ArgoCD**, et l'analyse de vulnérabilités avec **Trivy**.

Le projet illustre l'approche **GitOps** appliquée au DevSecOps : le dépôt Git est la source unique de vérité, ArgoCD synchronise automatiquement le cluster sur l'état déclaré, et chaque image Docker produite passe par deux étapes de scan avant publication.

## Architecture

```
                                ┌─────────────────────────────────────┐
                                │           Dépôt GitHub              │
                                │  (manifests + Dockerfile + CI)      │
                                └────────────┬────────────────────────┘
                                             │
                  git push                   │ watch
            ┌────────────────────────────────┼─────────────────────────┐
            │                                │                         │
            ▼                                ▼                         │
  ┌──────────────────┐              ┌────────────────┐                 │
  │  GitHub Actions  │              │    ArgoCD      │                 │
  │   CI Security    │              │  (synchro)     │                 │
  └────────┬─────────┘              └────────┬───────┘                 │
           │                                 │                         │
           │ build + 2 scans Trivy           │ kubectl apply           │
           ▼                                 ▼                         │
       ┌────────┐                  ┌───────────────────┐               │
       │  GHCR  │                  │  Cluster Kind     │ ─── selfHeal ─┘
       └────────┘                  │  (nginx pods)     │
                                   └─────────┬─────────┘
                                             │ pull
                                             ▼
                                   ┌───────────────────┐
                                   │ Harbor (proxy)    │
                                   │ 10.6.0.190:80     │
                                   └───────────────────┘
```
  Le choix de GHCR comme registry de destination s'explique par le contexte de ce TP. Le Harbor mis à disposition par l'IUT (10.6.0.190:80) est utilisé en mode proxy cache vers Docker Hub : il sert à pull des images officielles, mais sa configuration ne nous permet pas d'y pousser nos propres images. GHCR offre une alternative car il est gratuit, intégré nativement à GitHub Actions, et l'authentification se fait automatiquement via le GITHUB_TOKEN sans avoir à gérer de credentials supplémentaires. Dans ce contexte, on imagine que notre cluster tire par la suite ses images depuis GHCR pour boucler la chaîne GitOps.

## Composants

| Composant | Rôle |
|---|---|
| **GitHub Actions** | Pipeline CI (build, scan, push) sur runner self-hosted |
| **Kubernetes (Kind)** | Cluster local pour héberger l'application |
| **Harbor** | Registry Docker en mode proxy cache vers Docker Hub (`10.6.0.190:80`) |
| **Trivy** | Scanner de vulnérabilités, intégré à deux endroits du pipeline |
| **ArgoCD** | Déploiement continu basé sur GitOps |
| **GHCR** | Registry de destination pour les images certifiées par la CI |

## Structure du dépôt

```
.
├── .github/workflows/
│   └── fahh.yml              # Pipeline CI Security (GitHub Actions)
├── app/
│   ├── argocd-app.yaml       # Définition de l'application ArgoCD
│   ├── deployment.yaml       # Deployment Kubernetes (nginx)
│   └── service.yaml          # Service Kubernetes (NodePort)
├── Dockerfile                # Image nginx custom durcie
├── kind-config.yaml          # Configuration du cluster Kind
└── README.md
```

## Mise en route

### 1. Création du cluster Kind

```bash
kind create cluster --config kind-config.yaml
kubectl cluster-info --context kind-argocd-cluster
```

La configuration Kind redirige les ports 80/443 du cluster vers la machine hôte et déclare Harbor (`10.6.0.190:80`) comme mirror containerd, ce qui permet aux pods de pull des images via le proxy de l'IUT.

### 2. Installation d'ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Récupération du mot de passe admin et accès à l'interface :

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d && echo
```

L'interface est accessible sur https://localhost:8080 avec l'utilisateur `admin`. (En cas de problème d'accès, tester au préalable avec un curl pour valider la connectivité.)

### 3. Déclaration de l'application ArgoCD

```bash
kubectl apply -f app/argocd-app.yaml
```

ArgoCD watch désormais le dossier `app/` du dépôt et synchronise automatiquement le cluster avec son contenu (`syncPolicy.automated` avec `prune` et `selfHeal` activés).

## Pipeline CI Security

Le workflow `fahh.yml` se déclenche à chaque push sur `main` (ou manuellement via `workflow_dispatch`) et tourne sur un runner self-hosted. Il enchaîne sept étapes :

1. **Checkout** du dépôt
2. **Mise en minuscules** du nom de l'image (contrainte GHCR)
3. **Scan #1 — informatif** : Trivy analyse l'image de base `nginx:alpine` et remonte les CVE héritées de l'upstream sans bloquer (`exit-code: 0`)
4. **Build** de l'image custom à partir du Dockerfile
5. **Scan #2 — bloquant** : Trivy analyse l'image finale après durcissement. Toute CVE `HIGH` ou `CRITICAL` corrigeable provoque l'échec du job (`exit-code: 1`)
6. **Login** sur GHCR via `GITHUB_TOKEN`
7. **Push** de l'image vers `ghcr.io/<repo>:<sha>` et `:latest`

### Pourquoi un double scan ?

L'articulation entre les deux scans permet une vraie **séparation des responsabilités** :

- Si le scan #1 remonte des failles mais que le scan #2 passe → le durcissement appliqué dans le Dockerfile (`apk upgrade`) a bien fait son travail
- Si le scan #1 est propre mais que le scan #2 échoue → les failles viennent **directement des modifications du développeur**, ce qui permet une correction ciblée et rapide

Cette structure rend la dette de sécurité visible **avant** publication et garantit qu'aucune image vulnérable ne quitte le pipeline.

## Dockerfile

```dockerfile
FROM 10.6.0.190:80/proxy/nginx:alpine
RUN apk update && apk upgrade --no-cache
RUN echo "<h1>Defi 4</h1>" > /usr/share/nginx/html/index.html
EXPOSE 80
```

L'image part d'`nginx:alpine` (récupérée via le proxy Harbor), applique les correctifs Alpine disponibles via `apk upgrade --no-cache` pour éliminer les CVE upstream, puis customise la page d'accueil. Cette étape de durcissement est ce qui permet au scan #2 de passer alors que le scan #1 remonte des failles.

## Validation pédagogique du pipeline

Trois itérations ont été testées pour démontrer le comportement attendu du pipeline :

1. **Image non durcie** (`FROM nginx:1.27-alpine` sans `apk upgrade`) → le scan #1 remonte les CVE upstream, le scan #2 bloque le push
2. **Image durcie** (Dockerfile ci-dessus) → le scan #1 remonte les CVE upstream à titre informatif, le scan #2 valide l'image après durcissement, le push réussit
3. **Image avec faille introduite volontairement** → le scan #2 détecte la régression et bloque, validant le rôle de gate du second scan

## Prérequis

- Docker (avec le user dans le groupe `docker` ou accès `sudo`)
- Kind ≥ 0.20
- kubectl
- Un runner GitHub Actions self-hosted enregistré sur le dépôt
- Accès réseau au Harbor de l'IUT (`10.6.0.190:80`)
- Configuration Docker autorisant les insecure registries pour Harbor :

```json
// /etc/docker/daemon.json
{
  "insecure-registries": ["10.6.0.190:80"]
}
```

## Auteur

Eltchi ASLAMBEKOV

Claude
