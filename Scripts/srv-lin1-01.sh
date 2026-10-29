#!/usr/bin/env bash

# ============================================================
# SRV-LIN1-01 - INSTALLATION SERVEUR D'INFRASTRUCTURE
# ============================================================
# Système : Debian 13
#
# Services :
#   - Routeur IPv4 / NAT
#   - Serveur DNS BIND9
#   - Serveur DHCP ISC
#   - Serveur OpenLDAP
#   - LDAP Account Manager (LAM)
#   - Création des utilisateurs et groupes LDAP
#
# Exécution : sudo bash SRV-LIN1-01.sh
#
# ATTENTION :
# - Utiliser une VM Debian 13 neuve.
# - Deux interfaces réseau sont nécessaires.
# - Snapshot recommandé.
# - Le script modifie le réseau et les services.
# ============================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 077


# ============================================================
# 1. VARIABLES DE CONFIGURATION
# ============================================================

# --- Interfaces réseau ---
WAN_IF="${WAN_IF:-ens33}"
LAN_IF="${LAN_IF:-ens34}"

# --- Réseau local ---
LAN_IP="${LAN_IP:-10.10.10.11}"
LAN_CIDR="${LAN_CIDR:-24}"
LAN_NETWORK="10.10.10.0"
LAN_NETMASK="255.255.255.0"
LAN_SUBNET="${LAN_NETWORK}/${LAN_CIDR}"

# --- DNS ---
DOMAIN="${DOMAIN:-LIN1.local}"
DNS_FORWARDER="${DNS_FORWARDER:-192.168.122.2}"

# --- Serveurs du réseau ---
NEXTCLOUD_IP="10.10.10.22"
NAS_IP="10.10.10.33"

# --- DHCP ---
DHCP_START="10.10.10.100"
DHCP_END="10.10.10.200"
DHCP_LEASE_DEFAULT="600"
DHCP_LEASE_MAX="7200"

# --- LDAP ---
LDAP_ORGANIZATION="LIN1"
# Groupes / utilisateurs sur le modèle du script du collègue.
# On conserve le groupe Developpeur et dev02 pour le POC LIN1.
LDAP_GROUP="Developpeur"
LDAP_USER="dev02"
LDAP_GROUPS=("Manager:5000" "Ingenieur:5001" "Developpeur:5002")
LDAP_USERS=(
    "man01:Manager01:Man:10000:5000:Manager"
    "man02:Manager02:Man:10001:5000:Manager"
    "ing01:Ingenieur01:Ing:10002:5001:Ingenieur"
    "ing02:Ingenieur02:Ing:10003:5001:Ingenieur"
    "dev01:Developpeur01:Dev:10004:5002:Developpeur"
    "dev02:Developpeur02:Dev:10005:5002:Developpeur"
)

# --- Fichiers réseau ---
NETWORK_FILE="/etc/network/interfaces"
SYSCTL_FILE="/etc/sysctl.d/90-lin1-router.conf"

# --- Fichiers DNS ---
BIND_LOCAL="/etc/bind/named.conf.local"
BIND_OPTIONS="/etc/bind/named.conf.options"
BIND_ZONE="/etc/bind/db.${DOMAIN}"

# --- Fichiers DHCP ---
DHCP_DEFAULT="/etc/default/isc-dhcp-server"
DHCP_CONFIG="/etc/dhcp/dhcpd.conf"

# --- URL LAM ---
LAM_URL="http://${LAN_IP}/lam"

# --- Mots de passe de démonstration : VM TEST ISOLÉE UNIQUEMENT ---
# NE PAS publier cette configuration sur GitHub / ne pas utiliser en production.
LDAP_ADMIN_PASSWORD=${LDAP_ADMIN_PASSWORD:-'Pa$$w0rd'}
USER_DEFAULT_PASSWORD=${USER_DEFAULT_PASSWORD:-'Pa$$w0rd'}
LIN1_CONFIRM_FRESH_INSTALL="${LIN1_CONFIRM_FRESH_INSTALL:-YES}"

# Variables calculées dans check_prerequisites :
BASE_DN=""
ADMIN_DN=""
TMP_DIR=""


# ============================================================
# 2. FONCTIONS UTILITAIRES
# ============================================================

log() {
    printf '\n[LIN1-01] %s\n' "$*"
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
    local variable="$1"

    [[ -n "${!variable:-}" ]] || \
        error "Variable obligatoire absente : $variable"
}

backup_file() {
    local source="$1"
    local backup="${source}.lin1.bak"

    if [[ -f "$source" && ! -e "$backup" ]]; then
        cp -a "$source" "$backup"
        info "Sauvegarde : $backup"
    fi
}

on_error() {
    local line="$1"
    local command="$2"

    printf '\n[ERREUR] Ligne %s : %s\n' \
        "$line" "$command" >&2
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT


# ============================================================
# 3. VÉRIFICATION DES PRÉREQUIS
# ============================================================

check_prerequisites() {

    log "Vérification des prérequis"

    [[ "$EUID" -eq 0 ]] || \
        error "Exécuter le script en root."

    [[ -f /etc/debian_version ]] || \
        error "Debian est requis."

    [[ "${LIN1_CONFIRM_FRESH_INSTALL:-}" == "YES" ]] || \
        error "Définir LIN1_CONFIRM_FRESH_INSTALL=YES."

    require_var LDAP_ADMIN_PASSWORD
    require_var USER_DEFAULT_PASSWORD

    [[ "$WAN_IF" != "$LAN_IF" ]] || \
        error "WAN_IF et LAN_IF doivent être différents."

    ip link show "$WAN_IF" >/dev/null 2>&1 || \
        error "Interface WAN introuvable : $WAN_IF"

    ip link show "$LAN_IF" >/dev/null 2>&1 || \
        error "Interface LAN introuvable : $LAN_IF"

    [[ -f "$NETWORK_FILE" ]] || \
        error "Configuration ifupdown introuvable."

    # Ce script utilise un plan IPv4 fixe en /24.
    [[ "$LAN_CIDR" == "24" ]] || \
        error "Ce script est prévu pour un LAN /24."

    [[ "$LAN_IP" == "10.10.10.11" ]] || \
        error "Adapter tout le plan réseau avant de changer LAN_IP."

    # Validation simple du domaine DNS.
    [[ "$DOMAIN" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
        error "Nom de domaine invalide."

    # Construction automatique du DN de base LDAP.
    local part
    local -a domain_parts

    IFS='.' read -r -a domain_parts <<< "$DOMAIN"

    BASE_DN=""

    for part in "${domain_parts[@]}"; do
        if [[ -n "$BASE_DN" ]]; then
            BASE_DN+=","
        fi

        BASE_DN+="dc=${part}"
    done

    ADMIN_DN="cn=admin,${BASE_DN}"

    TMP_DIR="$(mktemp -d)"
    chmod 700 "$TMP_DIR"

    info "WAN        : $WAN_IF"
    info "LAN        : $LAN_IF"
    info "Adresse LAN: $LAN_IP/$LAN_CIDR"
    info "Domaine    : $DOMAIN"
    info "Base LDAP  : $BASE_DN"
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
# 4. PRÉCONFIGURATION OPENLDAP
# ============================================================

preconfigure_ldap() {

    log "Préconfiguration d'OpenLDAP"

    # Évite l'assistant interactif pendant l'installation.
    # Les secrets sont transmis à debconf via stdin.
    # Ils seront donc également stockés dans debconf.

    printf '%s\n' \
        "slapd slapd/no_configuration boolean false" \
        "slapd slapd/domain string ${DOMAIN}" \
        "slapd shared/organization string ${LDAP_ORGANIZATION}" \
        "slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}" \
        "slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}" \
        "slapd slapd/backend select MDB" \
        "slapd slapd/purge_database boolean false" \
        "slapd slapd/move_old_database boolean true" \
        | debconf-set-selections

    info "Préconfiguration LDAP enregistrée."
}


# ============================================================
# 5. INSTALLATION DES PAQUETS
# ============================================================

install_packages() {

    log "Installation des paquets Debian"

    prepare_apt_repositories
    apt-get update -o APT::Update::Error-Mode=any

    # Préparer debconf avant d'installer slapd.
    apt-get install -y debconf-utils
    preconfigure_ldap

    apt-get install -y \
        sudo \
        iptables \
        iptables-persistent \
        netfilter-persistent \
        isc-dhcp-server \
        bind9 \
        bind9-utils \
        dnsutils \
        slapd \
        ldap-utils \
        ldap-account-manager \
        apache2

    info "Paquets installés."
}


# ============================================================
# 6. CONFIGURATION DES INTERFACES RÉSEAU
# ============================================================

configure_network() {

    log "Configuration du réseau"

    backup_file "$NETWORK_FILE"

    cat > "$NETWORK_FILE" <<EOF
# =====================================================
# SRV-LIN1-01 - CONFIGURATION RÉSEAU
# =====================================================

# Boucle locale
auto lo
iface lo inet loopback

# Interface WAN - accès Internet par DHCP
allow-hotplug ${WAN_IF}
iface ${WAN_IF} inet dhcp

# Interface LAN - réseau interne statique
auto ${LAN_IF}
iface ${LAN_IF} inet static
    address ${LAN_IP}/${LAN_CIDR}
EOF

    # Activer immédiatement l'interface LAN.
    ip link set "$LAN_IF" up

    # Ajouter l'IP si elle n'existe pas.
    if ! ip -4 addr show dev "$LAN_IF" | \
        grep -Fq "inet ${LAN_IP}/${LAN_CIDR}"; then

        ip addr add \
            "${LAN_IP}/${LAN_CIDR}" \
            dev "$LAN_IF"
    fi

    info "Configuration réseau enregistrée."
    warn "L'interface WAN n'est pas redémarrée."
}


# ============================================================
# 7. ROUTAGE IPV4 ET NAT
# ============================================================

configure_nat() {

    log "Configuration du routage IPv4 et du NAT"

    # Activer le routage IPv4 de manière permanente.
    cat > "$SYSCTL_FILE" <<EOF
# Routage IPv4 - SRV-LIN1-01
net.ipv4.ip_forward=1
EOF

    # Application immédiate.
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # NAT : masquer les adresses du LAN vers Internet.
    if ! iptables -t nat -C POSTROUTING \
        -s "$LAN_SUBNET" \
        -o "$WAN_IF" \
        -j MASQUERADE 2>/dev/null; then

        iptables -t nat -A POSTROUTING \
            -s "$LAN_SUBNET" \
            -o "$WAN_IF" \
            -j MASQUERADE
    fi

    # Autoriser les communications LAN vers WAN.
    if ! iptables -C FORWARD \
        -i "$LAN_IF" \
        -o "$WAN_IF" \
        -s "$LAN_SUBNET" \
        -j ACCEPT 2>/dev/null; then

        iptables -A FORWARD \
            -i "$LAN_IF" \
            -o "$WAN_IF" \
            -s "$LAN_SUBNET" \
            -j ACCEPT
    fi

    # Autoriser uniquement les réponses WAN vers LAN.
    if ! iptables -C FORWARD \
        -i "$WAN_IF" \
        -o "$LAN_IF" \
        -d "$LAN_SUBNET" \
        -m conntrack \
        --ctstate ESTABLISHED,RELATED \
        -j ACCEPT 2>/dev/null; then

        iptables -A FORWARD \
            -i "$WAN_IF" \
            -o "$LAN_IF" \
            -d "$LAN_SUBNET" \
            -m conntrack \
            --ctstate ESTABLISHED,RELATED \
            -j ACCEPT
    fi

    # Sauvegarde des règles pour le redémarrage.
    netfilter-persistent save

    systemctl enable netfilter-persistent

    info "Routage IPv4 activé."
    info "Masquerading NAT configuré."
}


# ============================================================
# 8. CONFIGURATION DU SERVEUR DNS BIND9
# ============================================================

configure_dns() {

    log "Configuration du serveur DNS BIND9"

    backup_file "$BIND_LOCAL"
    backup_file "$BIND_OPTIONS"
    backup_file "$BIND_ZONE"

    # --------------------------------------------------------
    # 8.1 Déclaration de la zone DNS
    # --------------------------------------------------------

    cat > "$BIND_LOCAL" <<EOF
// Zone DNS locale - SRV-LIN1-01

zone "${DOMAIN}" {
    type master;
    file "${BIND_ZONE}";
};
EOF

    # --------------------------------------------------------
    # 8.2 Options générales BIND9
    # --------------------------------------------------------

    cat > "$BIND_OPTIONS" <<EOF
// Options BIND9 - SRV-LIN1-01

acl "Intern-Network" {
    127.0.0.1;
    ${LAN_SUBNET};
};

options {
    directory "/var/cache/bind";

    listen-on port 53 {
        127.0.0.1;
        ${LAN_IP};
    };

    listen-on-v6 { none; };

    allow-query {
        Intern-Network;
    };

    recursion yes;

    allow-recursion {
        Intern-Network;
    };

    forwarders {
        ${DNS_FORWARDER};
    };

    forward only;

    // Réseau de démonstration : le DNS forwarder VMware 192.168.122.2
    // provoque une chaîne DNSSEC invalide (SERVFAIL). Validation désactivée.
    dnssec-validation no;

    allow-transfer { none; };
};
EOF

    # --------------------------------------------------------
    # 8.3 Fichier de zone DNS
    # --------------------------------------------------------

    local serial
    serial="$(date +%Y%m%d%H)"

    cat > "$BIND_ZONE" <<EOF
\$TTL 86400

@ IN SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
    ${serial}  ; Serial
    3600       ; Refresh
    1800       ; Retry
    604800     ; Expire
    86400      ; Negative Cache TTL
)

; Serveur DNS principal
@ IN NS ns1.${DOMAIN}.

; Serveur infrastructure
ns1          IN A ${LAN_IP}
SRV-LIN1-01  IN A ${LAN_IP}

; Serveur Nextcloud
SRV-LIN1-02  IN A ${NEXTCLOUD_IP}

; Serveur NAS
NAS-LIN1-01  IN A ${NAS_IP}
EOF

    # --------------------------------------------------------
    # 8.4 Validation et démarrage
    # --------------------------------------------------------

    named-checkconf

    named-checkzone \
        "$DOMAIN" \
        "$BIND_ZONE"

    # Le script applique umask 077 : sans ces permissions, named
    # ne peut pas lire les fichiers générés par root.
    chmod 644 "$BIND_LOCAL" "$BIND_OPTIONS" "$BIND_ZONE"

    systemctl enable --now named
    systemctl restart named

    # Une zone valide sur disque doit aussi être chargée et répondre.
    rndc zonestatus "$DOMAIN" >/dev/null || \
        error "Zone DNS non chargée par named : $DOMAIN"
    local resolved
    resolved="$(dig @127.0.0.1 +short +time=3 +tries=1 \
        "SRV-LIN1-01.${DOMAIN}." A | head -n 1)"
    [[ "$resolved" == "$LAN_IP" ]] || \
        error "DNS local incorrect : attendu $LAN_IP, obtenu ${resolved:-aucune réponse}"

    info "DNS BIND9 configuré."
    info "Zone : $DOMAIN"
}


# ============================================================
# 9. CONFIGURATION DU SERVEUR DHCP
# ============================================================

configure_dhcp() {

    log "Configuration du serveur DHCP"

    backup_file "$DHCP_DEFAULT"
    backup_file "$DHCP_CONFIG"

    # --------------------------------------------------------
    # 9.1 Interface écoutant les requêtes DHCP
    # --------------------------------------------------------

    # Remplacer la configuration de l'interface DHCPv4.
    if grep -q '^INTERFACESv4=' "$DHCP_DEFAULT"; then

        sed -i \
            "s/^INTERFACESv4=.*/INTERFACESv4=\"${LAN_IF}\"/" \
            "$DHCP_DEFAULT"

    else
        printf 'INTERFACESv4="%s"\n' \
            "$LAN_IF" >> "$DHCP_DEFAULT"
    fi

    # --------------------------------------------------------
    # 9.2 Plage d'adresses DHCP
    # --------------------------------------------------------

    cat > "$DHCP_CONFIG" <<EOF
# =====================================================
# DHCP - SRV-LIN1-01
# =====================================================

authoritative;

option domain-name "${DOMAIN}";
option domain-name-servers ${LAN_IP};

default-lease-time ${DHCP_LEASE_DEFAULT};
max-lease-time ${DHCP_LEASE_MAX};

subnet ${LAN_NETWORK} netmask ${LAN_NETMASK} {

    range ${DHCP_START} ${DHCP_END};

    option routers ${LAN_IP};

    option subnet-mask ${LAN_NETMASK};

    option broadcast-address 10.10.10.255;
}
EOF

    # --------------------------------------------------------
    # 9.3 Validation et démarrage
    # --------------------------------------------------------

    chmod 644 "$DHCP_CONFIG"
    dhcpd -t -cf "$DHCP_CONFIG"

    systemctl enable isc-dhcp-server
    systemctl restart isc-dhcp-server

    info "DHCP configuré sur $LAN_IF."
    info "Plage : $DHCP_START - $DHCP_END"
}


# ============================================================
# 10. DÉMARRAGE ET VÉRIFICATION OPENLDAP
# ============================================================

configure_ldap() {

    log "Configuration du serveur OpenLDAP"

    systemctl enable --now slapd

    # Enregistrer le mot de passe dans un fichier temporaire
    # protégé, plutôt que dans la ligne de commande.
    printf '%s' "$LDAP_ADMIN_PASSWORD" \
        > "${TMP_DIR}/ldap-admin.pass"

    chmod 600 "${TMP_DIR}/ldap-admin.pass"

    # Vérifier que l'authentification fonctionne.
    ldapwhoami \
        -x \
        -H ldap://127.0.0.1 \
        -D "$ADMIN_DN" \
        -y "${TMP_DIR}/ldap-admin.pass" \
        >/dev/null || \
        error "Authentification administrateur LDAP impossible."

    info "OpenLDAP fonctionne."
    info "Administrateur : $ADMIN_DN"
}


# ============================================================
# 11. FONCTIONS LDAP
# ============================================================

ldap_exists() {

    local dn="$1"

    ldapsearch \
        -LLL \
        -x \
        -H ldap://127.0.0.1 \
        -b "$dn" \
        -s base \
        dn 2>/dev/null | grep -q '^dn:'
}

ldap_add_file() {

    local file="$1"

    ldapadd \
        -x \
        -H ldap://127.0.0.1 \
        -D "$ADMIN_DN" \
        -y "${TMP_DIR}/ldap-admin.pass" \
        -f "$file"
}

ldap_modify_file() {

    local file="$1"

    ldapmodify \
        -x \
        -H ldap://127.0.0.1 \
        -D "$ADMIN_DN" \
        -y "${TMP_DIR}/ldap-admin.pass" \
        -f "$file"
}


# ============================================================
# 12. CRÉATION DES UNITÉS ORGANISATIONNELLES
# ============================================================

create_ldap_organizational_units() {

    log "Création des unités organisationnelles LDAP"

    local ou
    local ldif="${TMP_DIR}/organizational-unit.ldif"

    for ou in People Groups; do

        if ldap_exists "ou=${ou},${BASE_DN}"; then
            info "OU ${ou} déjà présente."
            continue
        fi

        cat > "$ldif" <<EOF
dn: ou=${ou},${BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: ${ou}
EOF

        ldap_add_file "$ldif"

        info "OU ${ou} créée."
    done
}


# ============================================================
# 13. CRÉATION DES GROUPES LDAP
# ============================================================

create_ldap_group() {

    log "Création des groupes LDAP"

    local record name gid dn ldif="${TMP_DIR}/group.ldif"

    for record in "${LDAP_GROUPS[@]}"; do
        IFS=: read -r name gid <<< "$record"
        dn="cn=${name},ou=Groups,${BASE_DN}"

        if ldap_exists "$dn"; then
            info "Groupe ${name} déjà présent."
            continue
        fi

        cat > "$ldif" <<EOF
dn: ${dn}
objectClass: top
objectClass: posixGroup
cn: ${name}
gidNumber: ${gid}
EOF
        ldap_add_file "$ldif"
        info "Groupe ${name} créé."
    done
}


# ============================================================
# 14. CRÉATION DES UTILISATEURS LDAP
# ============================================================

create_ldap_user() {

    log "Création des utilisateurs LDAP"

    local record uid sn given uidnum gid group dn
    local ldif="${TMP_DIR}/user.ldif"
    local password_hash

    # Le mot de passe de démonstration est haché avant l'injection LDAP.
    printf '%s' "$USER_DEFAULT_PASSWORD" > "${TMP_DIR}/users.pass"
    chmod 600 "${TMP_DIR}/users.pass"
    password_hash="$(slappasswd -T "${TMP_DIR}/users.pass")"

    for record in "${LDAP_USERS[@]}"; do
        IFS=: read -r uid sn given uidnum gid group <<< "$record"
        dn="uid=${uid},ou=People,${BASE_DN}"

        if ldap_exists "$dn"; then
            info "Utilisateur ${uid} déjà présent."
            continue
        fi

        cat > "$ldif" <<EOF
dn: ${dn}
objectClass: top
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ${uid}
sn: ${sn}
givenName: ${given}
cn: ${uid}
displayName: ${uid}
uidNumber: ${uidnum}
gidNumber: ${gid}
homeDirectory: /home/${uid}
loginShell: /bin/bash
userPassword: ${password_hash}
EOF
        ldap_add_file "$ldif"
        info "Utilisateur ${uid} créé."
    done
}


# ============================================================
# 15. ASSOCIATION UTILISATEURS / GROUPES LDAP
# ============================================================

configure_ldap_membership() {

    log "Association des utilisateurs aux groupes LDAP"

    local record uid sn given uidnum gid group group_dn ldif
    ldif="${TMP_DIR}/membership.ldif"

    for record in "${LDAP_USERS[@]}"; do
        IFS=: read -r uid sn given uidnum gid group <<< "$record"
        group_dn="cn=${group},ou=Groups,${BASE_DN}"

        if ldapsearch -LLL -x -H ldap://127.0.0.1 \
            -b "$group_dn" -s base memberUid | \
            grep -Fxq "memberUid: ${uid}"; then
            info "${uid} déjà membre de ${group}."
            continue
        fi

        cat > "$ldif" <<EOF
dn: ${group_dn}
changetype: modify
add: memberUid
memberUid: ${uid}
EOF
        ldap_modify_file "$ldif"
        info "${uid} ajouté au groupe ${group}."
    done
}


# ============================================================
# 16. CONFIGURATION DE LDAP ACCOUNT MANAGER
# ============================================================

configure_lam() {

    log "Configuration de LDAP Account Manager"

    systemctl enable --now apache2
    apache2ctl configtest

    # Vérifier que LAM est bien installé.
    dpkg-query -W -f='${Status}' \
        ldap-account-manager | \
        grep -q "install ok installed" || \
        error "LDAP Account Manager n'est pas installé."

    systemctl restart apache2

    info "LDAP Account Manager installé."
    info "URL : $LAM_URL"

    warn "LAM est installé ; le profil doit être validé sur la VM (format dépend de la version Debian)."
    warn "Suffixe utilisateurs : ou=People,$BASE_DN"
    warn "Suffixe groupes      : ou=Groups,$BASE_DN"
}


# ============================================================
# 17. VÉRIFICATIONS FINALES
# ============================================================

final_checks() {

    log "Vérifications finales"

    # Services nécessaires.
    local service

    for service in \
        named \
        isc-dhcp-server \
        slapd \
        apache2; do

        if systemctl is-active --quiet "$service"; then
            info "Service actif : $service"
        else
            error "Service inactif : $service"
        fi
    done

    # Validation DNS.
    named-checkconf
    named-checkzone "$DOMAIN" "$BIND_ZONE"
    rndc zonestatus "$DOMAIN" >/dev/null || error "Zone DNS non chargée"
    [[ "$(dig @127.0.0.1 +short +time=3 +tries=1 "SRV-LIN1-01.${DOMAIN}." A | head -n 1)" == "$LAN_IP" ]] || \
        error "Résolution DNS locale incorrecte"

    # Validation DHCP.
    dhcpd -t -cf "$DHCP_CONFIG"

    # Validation Apache.
    apache2ctl configtest

    # Vérifier l'intégralité des comptes et groupes attendus.
    local record uid sn given uidnum gid group name
    for record in "${LDAP_USERS[@]}"; do
        IFS=: read -r uid sn given uidnum gid group <<< "$record"
        ldap_exists "uid=${uid},ou=People,${BASE_DN}" || \
            error "Utilisateur LDAP introuvable : $uid"
    done
    for record in "${LDAP_GROUPS[@]}"; do
        IFS=: read -r name gid <<< "$record"
        ldap_exists "cn=${name},ou=Groups,${BASE_DN}" || \
            error "Groupe LDAP introuvable : $name"
    done

    # Vérifier le routage.
    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || \
        error "Routage IPv4 désactivé."

    log "Installation terminée"

    printf '\n'
    printf '=============================================\n'
    printf ' SRV-LIN1-01 - SERVEUR INFRASTRUCTURE\n'
    printf '=============================================\n'
    printf ' WAN           : %s\n' "$WAN_IF"
    printf ' LAN           : %s\n' "$LAN_IF"
    printf ' Adresse       : %s/%s\n' "$LAN_IP" "$LAN_CIDR"
    printf ' Domaine       : %s\n' "$DOMAIN"
    printf ' DNS           : %s\n' "$LAN_IP"
    printf ' DHCP          : %s - %s\n' \
        "$DHCP_START" "$DHCP_END"
    printf ' Base LDAP     : %s\n' "$BASE_DN"
    printf ' Utilisateurs  : man01 man02 ing01 ing02 dev01 dev02\n'
    printf ' Groupes LDAP  : Manager Ingenieur Developpeur\n' 
    printf ' LAM           : %s\n' "$LAM_URL"
    printf '=============================================\n'

    info "Tests conseillés :"
    info "ip -br a"
    info "ip route"
    info "iptables -t nat -L -n -v"
    info "dig @${LAN_IP} SRV-LIN1-02.${DOMAIN}"
    info "ldapsearch -x -b '${BASE_DN}' '(objectClass=inetOrgPerson)' uid"

    warn "Terminer la configuration LAM."
    warn "Tester DHCP, DNS et NAT depuis une VM cliente."
}


# ============================================================
# 18. PROGRAMME PRINCIPAL
# ============================================================

main() {

    log "Démarrage de l'installation SRV-LIN1-01"

    check_prerequisites

    install_packages

    configure_network

    configure_nat

    configure_dns

    configure_dhcp

    configure_ldap

    create_ldap_organizational_units

    create_ldap_group

    create_ldap_user

    configure_ldap_membership

    configure_lam

    final_checks
}

main "$@"
