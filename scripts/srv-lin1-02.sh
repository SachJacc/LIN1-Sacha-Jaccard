#!/usr/bin/env bash

# ============================================================
# SRV-LIN1-02 - INSTALLATION SERVEUR NEXTCLOUD
# ============================================================
# Système : Debian 13
#
# Services :
#   - Serveur Apache2 / HTTPS
#   - Base de données MariaDB
#   - PHP et Nextcloud 34
#   - Connexion LDAP Nextcloud et utilisateurs LDAP
#   - Stockage externe NAS via NFS (optionnel, export à préciser)
#
# Exécution : sudo bash SRV-LIN1-02.sh
#
# ATTENTION :
# - Utiliser une VM Debian 13 neuve.
# - SRV-LIN1-01 doit fournir le DNS et la passerelle LAN.
# - Snapshot recommandé.
# - Le script modifie le réseau et les services.
# ============================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 027

# ============================================================
# 1. VARIABLES DE CONFIGURATION
# ============================================================

# Interface unique de SRV-LIN1-02 (VMware) : ens33
# Valeur fixe pour eviter une ancienne variable LAN_IF=ens37 dans le shell.
LAN_IF="ens33"
LAN_IP="${LAN_IP:-10.10.10.22}"
GATEWAY="${GATEWAY:-10.10.10.11}"
DNS_SERVER="${DNS_SERVER:-$GATEWAY}"
LAN_DOMAIN="${LAN_DOMAIN:-LIN1.local}"
NEXTCLOUD_VERSION="${NEXTCLOUD_VERSION:-34.0.0}"
NEXTCLOUD_DIR="/var/www/html/nextcloud"
NEXTCLOUD_DATA="/var/ncdata"
NC_ADMIN_USER="cpnv"
DB_NAME="nextcloud"
DB_USER="cpnv"
NAS_IP="${NAS_IP:-10.10.10.33}"
ENABLE_NFS="${ENABLE_NFS:-no}" # nécessite NAS_EXPORT réel pour activer NFS
NAS_MOUNT="/mnt/NAS-DATA"
LDAP_HOST="${LDAP_HOST:-10.10.10.11}"
LDAP_BASE="${LDAP_BASE:-dc=LIN1,dc=local}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=LIN1,dc=local}"
ENABLE_LDAP="${ENABLE_LDAP:-yes}"
# LDAP_BIND_PASSWORD requis si ENABLE_LDAP=yes.
# NAS_EXPORT doit correspondre exactement à un export déclaré sur le NAS.
NAS_EXPORT="${NAS_EXPORT:-}"

TMP_DIR=""

# --- Mots de passe de démonstration (VM isolée) ---
NC_ADMIN_PASSWORD=${NC_ADMIN_PASSWORD:-'Pa$$w0rd'}
NC_DB_PASSWORD=${NC_DB_PASSWORD:-'Pa$$w0rd'}
LDAP_BIND_PASSWORD=${LDAP_BIND_PASSWORD:-'Pa$$w0rd'}

# --- Validation de l'installation automatisée ---
LIN1_CONFIRM_FRESH_INSTALL="${LIN1_CONFIRM_FRESH_INSTALL:-YES}"

# Les suffixes doivent correspondre à SRV-LIN1-01 : People et Groups.
LDAP_USERS_OU="ou=People,${LDAP_BASE}"
LDAP_GROUPS_OU="ou=Groups,${LDAP_BASE}"

# ============================================================
# 2. FONCTIONS UTILITAIRES
# ============================================================

log() {
    printf '\n[LIN1-02] %s\n' "$*"
}

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[ATTENTION] %s\n' "$*" >&2
}

error() {
    printf '[ERREUR] %s\n' "$*" >&2
    exit 1
}

require_var() {
    [[ -n "${!1:-}" ]] || error "Variable obligatoire absente : $1"
}

on_error() {
    printf '[ERREUR] Ligne %s : %s\n' "$1" "$2" >&2
}

cleanup() {
    [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ============================================================
# 3. VÉRIFICATION DES PRÉREQUIS
# ============================================================

check_prerequisites() {
    log "Vérification des prérequis"
    [[ "$EUID" -eq 0 ]] || error "Exécuter le script en root."
    [[ -f /etc/debian_version ]] || error "Debian est requis."
    [[ "${LIN1_CONFIRM_FRESH_INSTALL:-}" == "YES" ]] || \
        error "Définir LIN1_CONFIRM_FRESH_INSTALL=YES."
    require_var NC_ADMIN_PASSWORD
    require_var NC_DB_PASSWORD
    [[ "$ENABLE_LDAP" == "yes" || "$ENABLE_LDAP" == "no" ]] || error "ENABLE_LDAP doit valoir yes ou no."
    if [[ "$ENABLE_LDAP" == yes ]]; then
        require_var LDAP_BIND_PASSWORD
    fi
    if [[ "$ENABLE_NFS" == yes ]]; then
        require_var NAS_EXPORT
    fi
    [[ "$ENABLE_NFS" == "yes" || "$ENABLE_NFS" == "no" ]] || \
        error "ENABLE_NFS doit valoir yes ou no."
    ip link show "$LAN_IF" >/dev/null 2>&1 || \
        error "Interface LAN introuvable : $LAN_IF"
    [[ -f /etc/network/interfaces ]] || error "ifupdown introuvable."
    info "LAN : $LAN_IF / $LAN_IP"
    info "Passerelle : $GATEWAY"
    info "Nextcloud : $NEXTCLOUD_VERSION"
    # Nextcloud/LDAP exigent un LAN opérationnel, pas seulement une route NAT.
    # Au besoin, démarrer depuis la console VMware (la migration réseau coupe SSH).
    if [[ "$ENABLE_LDAP" == yes ]]; then
        ping -c 1 -W 2 "$LDAP_HOST" >/dev/null || \
            error "SRV1 ($LDAP_HOST) injoignable : vérifier Host-Only, IP et passerelle."
    fi
}

# ============================================================
# DEPOTS APT DEBIAN 13 : NETINSTALL CD-ROM -> INTERNET
# ============================================================

prepare_apt_repositories() {
    log 'Préparation des dépôts Debian 13 (Trixie)'
    local f

    # Les entrées CD-ROM du netinstall empêchent apt-get update.
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        sed -i -E '/^[[:space:]]*deb[[:space:]]+cdrom:/s/^/# /' "$f"
    done

    # Une entrée deb822 ne contenant QUE le CD-ROM peut être désactivée.
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        if grep -Eqi '^URIs:[[:space:]]*cdrom:' "$f" && \
           ! grep -Eqi '^URIs:[[:space:]]*https?://' "$f"; then
            mv "$f" "${f}.lin1-cdrom-disabled"
            info "Dépôt CD-ROM désactivé : $f"
        fi
    done

    # Sources Internet standard Debian 13, sans écraser les autres dépôts.
    cat > /etc/apt/sources.list.d/lin1-debian.sources <<'APT'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
APT
}

# ============================================================
# 4. INSTALLATION DES PAQUETS
# ============================================================

install_packages() {
    log 'Paquets Debian'
    prepare_apt_repositories
    # Arrêt explicite si la résolution ou Internet sont indisponibles.
    getent ahostsv4 deb.debian.org >/dev/null || \
        error 'DNS indisponible : vérifier BIND sur SRV1 (10.10.10.11).'
    apt-get update -o APT::Update::Error-Mode=any
    apt-cache show apache2 >/dev/null 2>&1 || \
        error 'Paquet apache2 introuvable : dépôts Debian incomplets.'
    apt-get install -y sudo apache2 mariadb-server mariadb-client wget unzip ca-certificates openssl nfs-common open-iscsi ldap-utils \
      php php-cli libapache2-mod-php php-mysql php-common php-gd php-xml php-mbstring php-zip php-curl php-intl php-bcmath php-gmp php-imagick php-ldap php-apcu
}

# ============================================================
# 5. CONFIGURATION RÉSEAU ET DNS
# ============================================================

configure_network() {
    log 'Réseau et DNS'
    cp -an /etc/network/interfaces /etc/network/interfaces.lin1.bak || true
    cat > /etc/network/interfaces <<NET
auto lo
iface lo inet loopback
auto $LAN_IF
iface $LAN_IF inet static
    address $LAN_IP/24
    gateway $GATEWAY
    dns-nameservers $DNS_SERVER
    dns-search $LAN_DOMAIN
NET
    # La VM doit être sur le LAN Host-Only de SRV1 dès le départ.
    # Écrire la configuration permanente n'interrompt pas la session SSH.
    # Le routage effectif est vérifié avant le téléchargement de Nextcloud.
    if [[ ! -L /etc/resolv.conf ]]; then
      cp -an /etc/resolv.conf /etc/resolv.conf.lin1.bak || true
      cat > /etc/resolv.conf <<DNS
search $LAN_DOMAIN
nameserver $DNS_SERVER
DNS
    else
      echo '[ATTENTION] /etc/resolv.conf est géré par un service : vérifier le DNS après redémarrage.' >&2
    fi
    # Éviter un "succès" si le LAN de SRV2 n'a pas été configuré.
    if ! ip -4 -o addr show dev "$LAN_IF" | grep -Fq " $LAN_IP/24 "; then
        warn "Adresse $LAN_IP/24 absente sur $LAN_IF : application sans redémarrage SSH."
        ip link set "$LAN_IF" up
        ip -4 addr add "$LAN_IP/24" dev "$LAN_IF"
    fi
    ip route get "$GATEWAY" >/dev/null || error "Passerelle $GATEWAY inaccessible."
}

# ============================================================
# 6. CONFIGURATION DE MARIADB
# ============================================================

configure_database() {
    log 'Base MariaDB Nextcloud'
    systemctl enable --now mariadb apache2
    # Utiliser le client local root unix_socket et échapper le mot de passe SQL.
    DB_PASS_SQL=${NC_DB_PASSWORD//\\/\\\\}
    DB_PASS_SQL=${DB_PASS_SQL//\'/\'\'}
    mariadb <<SQL
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'cpnv'@'localhost' IDENTIFIED BY '$DB_PASS_SQL';
ALTER USER 'cpnv'@'localhost' IDENTIFIED BY '$DB_PASS_SQL';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'cpnv'@'localhost';
FLUSH PRIVILEGES;
SQL
}

# ============================================================
# 7. TÉLÉCHARGEMENT ET PERMISSIONS NEXTCLOUD
# ============================================================

install_nextcloud() {
    log 'Installation Nextcloud (version fixée par variable NEXTCLOUD_VERSION)'
    if [[ ! -f "${NEXTCLOUD_DIR}/occ" ]]; then
      TMP_DIR=$(mktemp -d)
      
      wget -q --show-progress "https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip" -O "$TMP_DIR/nextcloud.zip"
      unzip -tq "$TMP_DIR/nextcloud.zip" >/dev/null
      unzip -q "$TMP_DIR/nextcloud.zip" -d /var/www/html/
    fi
    [[ -f "${NEXTCLOUD_DIR}/occ" ]] || { echo '[ERREUR] Nextcloud occ introuvable' >&2; exit 1; }
    chown -R www-data:www-data "$NEXTCLOUD_DIR"
    mkdir -p "$NEXTCLOUD_DATA"
    chown www-data:www-data "$NEXTCLOUD_DATA"
}

# ============================================================
# 8. APACHE ET CERTIFICAT HTTPS
# ============================================================

configure_apache() {
    cat > /etc/apache2/sites-available/nextcloud.conf <<APACHE
<VirtualHost *:80>
    ServerName $LAN_IP
    Redirect permanent / https://$LAN_IP/
</VirtualHost>
<VirtualHost *:443>
    ServerName $LAN_IP
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/lin1-nextcloud.crt
    SSLCertificateKeyFile /etc/ssl/private/lin1-nextcloud.key
    <Directory ${NEXTCLOUD_DIR}>
            Require all granted
            AllowOverride All
            Options FollowSymLinks MultiViews
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
APACHE
    if [[ ! -f /etc/ssl/certs/lin1-nextcloud.crt ]]; then
      openssl req -x509 -nodes -newkey rsa:3072 -days 365 -subj "/CN=$LAN_IP" \
        -addext "subjectAltName=IP:$LAN_IP" \
        -keyout /etc/ssl/private/lin1-nextcloud.key -out /etc/ssl/certs/lin1-nextcloud.crt
      chmod 600 /etc/ssl/private/lin1-nextcloud.key
    fi
    a2enmod ssl rewrite headers env dir mime >/dev/null
    a2dissite 000-default >/dev/null || true
    a2ensite nextcloud >/dev/null
    apache2ctl configtest
    systemctl restart apache2
}

# ============================================================
# 9. INITIALISATION NEXTCLOUD
# ============================================================

initialize_nextcloud() {
    if [[ ! -f ${NEXTCLOUD_DIR}/config/config.php ]]; then
      runuser -u www-data -- \
        php "${NEXTCLOUD_DIR}/occ" maintenance:install \
        --database mysql --database-name nextcloud --database-user cpnv \
        --database-pass "$NC_DB_PASSWORD" --admin-user cpnv \
        --admin-pass "$NC_ADMIN_PASSWORD" --data-dir "$NEXTCLOUD_DATA"
    fi
}

# ============================================================
# 10. PARAMÈTRES NEXTCLOUD
# ============================================================

configure_nextcloud() {
    runuser -u www-data -- php "${NEXTCLOUD_DIR}/occ" config:system:set trusted_domains 1 --value="$LAN_IP"
    runuser -u www-data -- php "${NEXTCLOUD_DIR}/occ" config:system:set overwrite.cli.url --value="https://$LAN_IP/nextcloud"
    runuser -u www-data -- php "${NEXTCLOUD_DIR}/occ" config:system:set htaccess.RewriteBase --value='/nextcloud'
    runuser -u www-data -- php "${NEXTCLOUD_DIR}/occ" maintenance:update:htaccess
}

# ============================================================
# 11. CONNEXION LDAP NEXTCLOUD
# ============================================================

configure_ldap() {
    log 'Connexion LDAP Nextcloud'
    [[ "$ENABLE_LDAP" == yes ]] || { info 'LDAP désactivé explicitement.'; return; }
    local occ="${NEXTCLOUD_DIR}/occ" config_id
    # Vérifier le serveur avant d'écrire une configuration LDAP Nextcloud.
    ldapwhoami -x -H "ldap://${LDAP_HOST}:389" -D "$LDAP_BIND_DN" \
      -y <(printf '%s' "$LDAP_BIND_PASSWORD") >/dev/null || \
      error 'Authentification vers SRV-LIN1-01 échouée.'
    runuser -u www-data -- php "$occ" app:enable user_ldap
    # Sur une nouvelle installation, la première configuration est s01.
    # Une exécution répétée ne doit pas multiplier les profils.
    if ! runuser -u www-data -- php "$occ" ldap:show-config s01 >/dev/null 2>&1; then
        runuser -u www-data -- php "$occ" ldap:create-empty-config
    fi
    config_id=s01
    local key value
    while IFS='|' read -r key value; do
        runuser -u www-data -- php "$occ" ldap:set-config "$config_id" "$key" "$value"
    done <<LDAPSETTINGS
ldapHost|ldap://${LDAP_HOST}
ldapPort|389
ldapBase|${LDAP_BASE}
ldapBaseUsers|${LDAP_USERS_OU}
ldapBaseGroups|${LDAP_GROUPS_OU}
ldapAgentName|${LDAP_BIND_DN}
ldapUserDisplayName|cn
ldapGroupDisplayName|cn
ldapUserFilter|(objectClass=posixAccount)
ldapGroupFilter|(objectClass=posixGroup)
ldapLoginFilter|(&(objectClass=posixAccount)(uid=%uid))
ldapGroupMemberAssocAttr|memberUid
ldapExpertUsernameAttr|uid
ldapConfigurationActive|0
LDAPSETTINGS
    # occ exige un argument pour le secret. Usage uniquement en VM de démo.
    runuser -u www-data -- php "$occ" ldap:set-config "$config_id" \
      ldapAgentPassword "$LDAP_BIND_PASSWORD"
    runuser -u www-data -- php "$occ" ldap:set-config "$config_id" ldapConfigurationActive 1
    runuser -u www-data -- php "$occ" ldap:test-config "$config_id" || \
      error 'Profil LDAP Nextcloud invalide.'
    # Vérification d'un compte réellement peuplé par SRV1.
    runuser -u www-data -- php "$occ" ldap:search dev02 >/dev/null || \
       error 'Recherche LDAP de dev02 impossible depuis Nextcloud.'
    info 'Profil LDAP Nextcloud configuré.'
}

# ============================================================
# 12. STOCKAGE NAS / NFS OPTIONNEL
# ============================================================

configure_nfs() {
    log 'Stockage NAS (facultatif, NFS déjà exporté depuis OpenMediaVault)'
    if [[ "$ENABLE_NFS" == 'yes' ]]; then
      mkdir -p /mnt/NAS-DATA
      grep -qE '^[^#]*[[:space:]]/mnt/NAS-DATA[[:space:]]' /etc/fstab || \
        echo "$NAS_IP:$NAS_EXPORT /mnt/NAS-DATA nfs defaults,_netdev,nofail 0 0" >> /etc/fstab
      mountpoint -q /mnt/NAS-DATA || mount /mnt/NAS-DATA
      # Les permissions restent définies sur le NAS ; ne pas les contourner.
      runuser -u www-data -- test -r /mnt/NAS-DATA || \
        error 'Le répertoire NFS n’est pas lisible par www-data.'
      local occ="${NEXTCLOUD_DIR}/occ"
      runuser -u www-data -- php "$occ" app:enable files_external
      # Mount global Nextcloud basé sur le montage local NFS existant.
      if ! runuser -u www-data -- php "$occ" files_external:list --output=json | \
           grep -Fq 'NAS-DATA'; then
        runuser -u www-data -- php "$occ" files_external:create \
          '/NAS-DATA' local null::null --config "datadir=${NAS_MOUNT}"
      fi
    fi
}

# ============================================================
# 13. VÉRIFICATIONS FINALES
# ============================================================

final_checks() {
    apache2ctl configtest
    systemctl is-active --quiet apache2
    systemctl is-active --quiet mariadb
    runuser -u www-data -- php "${NEXTCLOUD_DIR}/occ" status
    runuser -u www-data -- php "${NEXTCLOUD_DIR}/occ" status --output=json | \
        grep -q '"installed":true' || error 'Nextcloud pas installé.'
    if [[ "$ENABLE_NFS" == yes ]]; then
        mountpoint -q "$NAS_MOUNT" || error 'Montage NAS absent.'
    fi
}

# ============================================================
# 14. PROGRAMME PRINCIPAL
# ============================================================

main() {
    log "Démarrage de l'installation SRV-LIN1-02"
    check_prerequisites
    install_packages
    configure_network
    configure_database
    install_nextcloud
    configure_apache
    initialize_nextcloud
    configure_nextcloud
    configure_ldap
    configure_nfs
    final_checks
    log "Installation terminée"
    info "URL : https://${LAN_IP}/nextcloud"
    info "Administrateur : ${NC_ADMIN_USER}"
    warn "Vérifier la connexion LDAP de dev02 et l'accès au NAS depuis un client."
    warn "iSCSI : configuration non incluse sans IQN, LUN et authentification de la cible."
}

main "$@"
