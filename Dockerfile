# Proxmox Datacenter Manager - image conteneur (sans systemd).
# Installe les paquets .deb officiels Proxmox depuis le dépôt PDM.
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="Proxmox Datacenter Manager"
LABEL org.opencontainers.image.description="Containerized Proxmox Datacenter Manager (PDM) - amd64, no systemd"
LABEL org.opencontainers.image.source="https://github.com/williamboglietti/proxmox-datacenter-manager"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NOWARNINGS=yes

# SHA256 attendu du keyring officiel Proxmox (vérifié au build).
ARG PROXMOX_KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

# 1. Dépendances système minimales.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        ca-certificates \
        procps \
        tini && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Keyring GPG Proxmox + vérification SHA256 (le build échoue en cas de mismatch).
RUN wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg && \
    echo "${PROXMOX_KEYRING_SHA256}  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c -

# 3. Dépôt apt PDM (format deb822).
RUN printf '%s\n' \
        'Types: deb' \
        'URIs: http://download.proxmox.com/debian/pdm' \
        'Suites: trixie' \
        'Components: pdm-no-subscription' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/proxmox.sources

# 4. Installe le méta-paquet orienté conteneur + l'interface web.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        proxmox-datacenter-manager-container-meta \
        proxmox-datacenter-manager-ui && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 5. Dossiers runtime et de persistance.
RUN mkdir -p \
        /run/proxmox-datacenter-manager \
        /etc/proxmox-datacenter-manager \
        /var/lib/proxmox-datacenter-manager \
        /var/log/proxmox-datacenter-manager && \
    chown -R www-data:www-data \
        /var/lib/proxmox-datacenter-manager \
        /var/log/proxmox-datacenter-manager

COPY disable-subscription-nag.html /usr/local/share/pdm/disable-subscription-nag.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8443

VOLUME ["/etc/proxmox-datacenter-manager", "/var/lib/proxmox-datacenter-manager"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
