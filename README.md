# Proxmox Datacenter Manager (Docker)

**Français** · [English](#english)

Image conteneur de [Proxmox Datacenter Manager](https://proxmox.com/en/products/proxmox-datacenter-manager/overview)
(PDM), construite à partir des paquets `.deb` officiels Proxmox et fonctionnant sans systemd.

> **Note :** image destinée aux home labs et aux tests. Ce n'est pas une méthode de
> déploiement officiellement supportée par Proxmox. Pour la production, suivre le
> [guide d'installation officiel](https://pdm.proxmox.com/docs/installation.html).

> **Architecture :** `linux/amd64` uniquement. Proxmox ne publie pas de paquets PDM pour arm64.

## Images

| Registry   | Référence                                            |
| ---------- | ---------------------------------------------------- |
| GHCR       | `ghcr.io/williamboglietti/proxmox-datacenter-manager`|
| Docker Hub | `williamboglietti/proxmox-datacenter-manager`        |

Les tags suivent la version PDM amont (ex. `1.1.4`, `1.1`, `latest`).

## Démarrage rapide

### docker run

```bash
docker run -d --name pdm \
  -p 8443:8443 \
  -e PDM_ROOT_PASSWORD=change-me \
  -v pdm-config:/etc/proxmox-datacenter-manager \
  -v pdm-data:/var/lib/proxmox-datacenter-manager \
  ghcr.io/williamboglietti/proxmox-datacenter-manager:latest
```

### Docker Compose

```bash
cp .env.example .env   # définir PDM_ROOT_PASSWORD
docker compose up -d
```

Ouvrir `https://<hôte>:8443` (certificat auto-signé) et se connecter avec le realm
`root@pam` et le mot de passe configuré.

## Configuration

| Variable                   | Défaut  | Description                                                       |
| -------------------------- | ------- | ---------------------------------------------------------------- |
| `PDM_ROOT_PASSWORD`        | —       | Mot de passe `root@pam`, appliqué au premier démarrage.          |
| `PDM_PORT`                 | `8443`  | Port HTTPS de l'UI/API.                                          |
| `DISABLE_SUBSCRIPTION_NAG` | `false` | Si `true`, masque le popup « Aucun abonnement en cours de validité ». |
| `DISABLE_ENTERPRISE_REPO`  | `false` | Si `true`, désactive le dépôt apt enterprise (évite les 401 sur `apt update` sans abonnement). |

Si `PDM_ROOT_PASSWORD` n'est pas fourni, définir le mot de passe manuellement :

```bash
docker exec -it pdm passwd
docker restart pdm
```

### Masquer le popup d'abonnement

Avec `DISABLE_SUBSCRIPTION_NAG=true`, le point d'entrée ajoute à `index.hbs` un
intercepteur `fetch` qui réécrit la réponse de `/nodes/localhost/subscription`
(`status` → `active`), ce qui empêche l'affichage du popup. Les binaires serveur
ne sont pas modifiés et le réglage est réversible (repasser la variable à `false`
puis redémarrer).

## Persistance

| Volume                                | Contenu                          |
| ------------------------------------- | -------------------------------- |
| `/etc/proxmox-datacenter-manager`     | Configuration, certificats, clés |
| `/var/lib/proxmox-datacenter-manager` | État, base de données            |

## Architecture

PDM tourne sous forme de deux daemons, comme sur une installation native, supervisés
par un petit point d'entrée sous `tini` :

- `proxmox-datacenter-privileged-api` — exécuté en root, expose le socket UNIX
  `/run/proxmox-datacenter-manager/priv.sock`.
- `proxmox-datacenter-api` — exécuté en `www-data`, sert l'API et l'UI web en HTTPS
  sur le port 8443.

## Build local

```bash
docker build -t pdm:local .
docker run -d --name pdm -p 8443:8443 -e PDM_ROOT_PASSWORD=change-me pdm:local
```

## Releases

Un workflow GitHub Actions construit l'image et la publie sur GHCR et Docker Hub à
chaque tag `v*`. Pour publier une nouvelle version alignée sur une release PDM :

```bash
git tag v1.1.4
git push origin v1.1.4
```

La publication sur Docker Hub nécessite les secrets de dépôt `DOCKERHUB_USERNAME`
et `DOCKERHUB_TOKEN`.

## Licence

MIT pour les fichiers de packaging de ce dépôt. Les composants Proxmox embarqués
sont sous AGPL-3.0 — voir le fichier [`NOTICE`](NOTICE) pour le détail des licences
et des sources. Basé sur la [documentation officielle Proxmox](https://pdm.proxmox.com/docs/)
et le dépôt de paquets `download.proxmox.com/debian/pdm`. Proxmox® est une marque
déposée de Proxmox Server Solutions GmbH ; ce projet n'est ni affilié ni approuvé
par Proxmox.

---

## English

Container image for [Proxmox Datacenter Manager](https://proxmox.com/en/products/proxmox-datacenter-manager/overview)
(PDM), built from the official Proxmox `.deb` packages and running without systemd.

> **Note:** This image is intended for home labs and testing. It is not an
> officially supported Proxmox deployment method. For production use, follow the
> [official installation guide](https://pdm.proxmox.com/docs/installation.html).

> **Architecture:** `linux/amd64` only. Proxmox does not publish PDM packages for arm64.

### Images

| Registry   | Reference                                            |
| ---------- | ---------------------------------------------------- |
| GHCR       | `ghcr.io/williamboglietti/proxmox-datacenter-manager`|
| Docker Hub | `williamboglietti/proxmox-datacenter-manager`        |

Tags follow the upstream PDM version (e.g. `1.1.4`, `1.1`, `latest`).

### Quick start

#### docker run

```bash
docker run -d --name pdm \
  -p 8443:8443 \
  -e PDM_ROOT_PASSWORD=change-me \
  -v pdm-config:/etc/proxmox-datacenter-manager \
  -v pdm-data:/var/lib/proxmox-datacenter-manager \
  ghcr.io/williamboglietti/proxmox-datacenter-manager:latest
```

#### Docker Compose

```bash
cp .env.example .env   # set PDM_ROOT_PASSWORD
docker compose up -d
```

Open `https://<host>:8443` (self-signed certificate) and log in with the `root@pam`
realm and the configured password.

### Configuration

| Variable                   | Default | Description                                            |
| -------------------------- | ------- | ------------------------------------------------------ |
| `PDM_ROOT_PASSWORD`        | —       | `root@pam` password, applied on first start.           |
| `PDM_PORT`                 | `8443`  | HTTPS port for the UI/API.                             |
| `DISABLE_SUBSCRIPTION_NAG` | `false` | When `true`, hides the "No valid subscription" dialog. |
| `DISABLE_ENTERPRISE_REPO`  | `false` | When `true`, disables the enterprise apt repository (avoids 401s on `apt update` without a subscription). |

If `PDM_ROOT_PASSWORD` is not provided, set the password manually:

```bash
docker exec -it pdm passwd
docker restart pdm
```

#### Hiding the subscription dialog

When `DISABLE_SUBSCRIPTION_NAG=true`, the entrypoint appends a small `fetch`
interceptor to `index.hbs` that rewrites the response of
`/nodes/localhost/subscription` (`status` → `active`), which prevents the dialog
from being shown. The server binaries are not modified, and the change is
reversible (set the variable back to `false` and restart).

### Persistence

| Volume                                | Contents                          |
| ------------------------------------- | --------------------------------- |
| `/etc/proxmox-datacenter-manager`     | Configuration, certificates, keys |
| `/var/lib/proxmox-datacenter-manager` | State, database                   |

### Architecture

PDM runs as two daemons, as on a native installation, supervised by a small
entrypoint under `tini`:

- `proxmox-datacenter-privileged-api` — runs as root, exposes the UNIX socket
  `/run/proxmox-datacenter-manager/priv.sock`.
- `proxmox-datacenter-api` — runs as `www-data`, serves the API and web UI over
  HTTPS on port 8443.

### Building locally

```bash
docker build -t pdm:local .
docker run -d --name pdm -p 8443:8443 -e PDM_ROOT_PASSWORD=change-me pdm:local
```

### Releases

A GitHub Actions workflow builds the image and publishes it to GHCR and Docker Hub
on every `v*` tag. To publish a new version matching an upstream PDM release:

```bash
git tag v1.1.4
git push origin v1.1.4
```

Publishing to Docker Hub requires the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`
repository secrets.

### License

MIT for the packaging files in this repository. The bundled Proxmox components are
licensed under AGPL-3.0 — see the [`NOTICE`](NOTICE) file for license and source
details. Based on the official [Proxmox documentation](https://pdm.proxmox.com/docs/)
and the `download.proxmox.com/debian/pdm` package repository. Proxmox® is a
registered trademark of Proxmox Server Solutions GmbH; this project is not
affiliated with or endorsed by Proxmox.
