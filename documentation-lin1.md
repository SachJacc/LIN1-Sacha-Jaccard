# LIN1-Sacha-Jaccard

# LIN1 - DOCUMENTATION TECHNIQUE DE L’INFRASTRUCTURE

**Système :** Debian 13.6.0 (serveurs Linux)  
**Contexte :** projet pédagogique LIN1 - environnement VMware de laboratoire.

## Présentation et objectifs

Le projet consiste à déployer une infrastructure virtuelle avec routage et accès Internet, résolution DNS, attribution DHCP, annuaire LDAP, stockage NAS redondant et plateforme collaborative Nextcloud. La documentation présente la configuration réalisée, les vérifications, le dépannage, la maintenance et les limites identifiées.

### Architecture et machines

| Machine     | Adresse                   | Fonction principale                              |
| ----------- | ------------------------- | ------------------------------------------------ |
| SRV-LIN1-01 | `10.10.10.11/24`          | Routage/NAT, DHCP, DNS BIND9, LDAP et LAM        |
| SRV-LIN1-02 | `10.10.10.22/24`          | Apache, MariaDB, Nextcloud, clients NFS et iSCSI |
| NAS-LIN1-01 | `10.10.10.33/24`          | OpenMediaVault, RAID 1, NFS, SMB et iSCSI        |
| CLI-LIN1-01 | DHCP (`10.10.10.100–200`) | Client Linux graphique et accès web              |
| WIN-LIN1-01 | DHCP (`10.10.10.100–200`) | Windows 11 Pro et synchronisation Nextcloud      |

**Réseau interne :** `10.10.10.0/24` ; passerelle et DNS des clients : `10.10.10.11` ; domaine interne : `LIN1.local`. Le serveur SRV-LIN1-01 possède une seconde interface pour l'accès externe.

> **Conventions :** les blocs `bash` sont des commandes à exécuter dans un terminal ; les blocs `ini`, `conf`, `fstab`, `ldif`, `sql` ou `text` décrivent du contenu à placer dans un fichier ou à saisir dans l'interface indiquée. Les périphériques `/dev/sdX`, interfaces `ensXX` et UUID sont spécifiques à cette maquette : vérifier les valeurs avant de les réutiliser.

# SOMMAIRE

- [Installation des serveurs](#installation-des-serveurs)
- [Configuration réseau des serveurs](#configuration-réseau-des-serveurs)
- [Configuration DHCP](#configuration-dhcp)
- [Configuration DNS](#configuration-dns)
- [Configuration SSH](#configuration-ssh)
- [Installation de Nextcloud](#installation-de-nextcloud-srv-lin1-02)
- [Installation du client Linux](#installation-et-configuration-du-client-linux)
- [Installation et configuration LDAP](#installation-et-configuration-ldap-srv-lin1-01)
- [Connexion Nextcloud et LDAP](#connexion-nextcloud-et-ldap-srv-lin-02)
- [Installation du NAS et du stockage](#installation-du-nas)
- [Dépannage](#dépannage)
- [Maintenance](#maintenance)
- [Bonnes pratiques et sécurité](#bonnes-pratiques-et-sécurité)
- [Limites techniques et avertissements](#limites-techniques-et-avertissements)

---

## Informations d'identification

### Admin

```
Nom d'utilisateur: root
Mot de passe: `<mot-de-passe-à-renseigner>`
```

### Utilisateur(s)

```
Nom d'utilisateur: `cpnv`
Mot de passe `<mot-de-passe-à-renseigner>`
```

---

# INSTALLATION DES SERVEURS

## Paramètres d'installation SRV-LIN-01 et 02

- Pas d'interface graphique ni de GNOME
- Ajout du service SSH
- Ajout de GRUB dans /dev/sda

## Installations de base

```bash
apt update
apt install sudo
```

---

# CONFIGURATION RÉSEAU DES SERVEURS

## Adressage IP (SRV-LIN1-01)

**Commande :**

```bash
nano /etc/network/interfaces
```

**Contenu de configuration à insérer pour `ens34` :**

```ini
auto ens34
iface ens34 inet static
    address 10.10.10.11/24
```

**Application et vérification (depuis la console locale, car la connexion réseau peut être interrompue) :**

```bash
ifdown ens34 2>/dev/null
ifup ens34
ip -br addr
```

## Adressage IP (SRV-LIN1-02)

**Commande :**

```bash
nano /etc/network/interfaces
```

**Contenu pour `ens33` :**

```ini
auto ens33
iface ens33 inet static
    address 10.10.10.22/24
    gateway 10.10.10.11
```

**Application et vérification :**

```bash
ifdown ens33 2>/dev/null
ifup ens33
ip -br addr
ip route
```

## Activation du routage et du NAT (SRV-LIN1-01)

Activer temporairement le routage, puis rendre cette option persistante :

```bash
sysctl -w net.ipv4.ip_forward=1
nano /etc/sysctl.conf
```

**Ligne à définir dans `/etc/sysctl.conf` :**

```ini
net.ipv4.ip_forward=1
```

**Appliquer et vérifier :**

```bash
sysctl -p /etc/sysctl.conf
sysctl net.ipv4.ip_forward
ip route
apt update
apt install iptables
iptables -t nat -A POSTROUTING -o ens33 -j MASQUERADE
iptables -t nat -L -n -v
```

> **Attention :** cette règle `iptables` est ajoutée pour la session courante. Pour un redémarrage reproductible, prévoir sa persistance et vérifier que `ens33` correspond bien à l'interface externe.

## Vérification internet (SRV-LIN1-02)

```bash
ping 10.10.10.11
ping 8.8.8.8
```

---

# CONFIGURATION DHCP

## Installation du DHCP (SRV-LIN1-01)

Le serveur DHCP attribue automatiquement aux clients les paramètres réseau (IP, passerelle et DNS) sur le réseau `10.10.10.0/24`.

**Installer le service et ouvrir son fichier de paramètres :**

```bash
sudo apt update && sudo apt install isc-dhcp-server
sudo nano /etc/default/isc-dhcp-server
```

**Ligne de configuration à définir :**

```ini
INTERFACESv4="ens34"
```

**Ouvrir le fichier de configuration DHCP :**

```bash
sudo nano /etc/dhcp/dhcpd.conf
```

**Bloc de configuration à ajouter :**

```conf
subnet 10.10.10.0 netmask 255.255.255.0 {
    range 10.10.10.100 10.10.10.200;
    option routers 10.10.10.11;
    option domain-name "LIN1.local";
    option domain-name-servers 10.10.10.11;
}
```

**Contrôle :**

```bash
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
sudo systemctl restart isc-dhcp-server
sudo systemctl status isc-dhcp-server --no-pager
```

---

# Configuration DNS

## Installation du DNS (SRV-LIN1-01)

BIND9 assure la résolution des noms de la zone interne `LIN1.local` et relaie les requêtes externes au résolveur configuré.

**Installation :**

```bash
sudo apt update && sudo apt install bind9 bind9utils
sudo nano /etc/bind/named.conf.local
```

**Déclaration de zone dans `/etc/bind/named.conf.local` :**

```conf
zone "LIN1.local" {
    type master;
    file "/var/cache/bind/db.LIN1.local";
};
```

**Ouvrir les options :**

```bash
sudo nano /etc/bind/named.conf.options
```

**Contenu de `/etc/bind/named.conf.options` :**

```conf
acl "Intern-Network" {
    127.0.0.1;
    10.10.10.0/24;
};

options {
    directory "/var/cache/bind";
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    allow-query { Intern-Network; };
    recursion yes;
    allow-recursion { Intern-Network; };
    forwarders { 192.168.122.2; };
    forward only;
    dnssec-validation no;
    allow-transfer { none; };
};
```

**Ouvrir la zone DNS :**

```bash
sudo nano /var/cache/bind/db.LIN1.local
```

**Contenu de la zone :**

```dns
$TTL 86400
@ IN SOA ns1.LIN1.local. admin.LIN1.local. (
    2026083101
    3600
    1800
    604800
    86400
)
@            IN NS ns1.LIN1.local.
ns1          IN A 10.10.10.11
SRV-LIN1-01  IN A 10.10.10.11
SRV-LIN1-02  IN A 10.10.10.22
NAS-LIN1-01  IN A 10.10.10.33
```

**Validation et redémarrage :**

```bash
sudo named-checkconf
sudo named-checkzone LIN1.local /var/cache/bind/db.LIN1.local
sudo systemctl restart bind9
sudo systemctl status bind9 --no-pager
```

> **Limite du laboratoire :** le résolveur `192.168.122.2` dépend de la configuration du réseau externe de la VM ; `dnssec-validation no` est un choix de laboratoire, non recommandé comme configuration générale de production.

## Configuration de la résolution DNS (SRV-LIN1-01)

**Ouvrir le fichier :**

```bash
sudo nano /etc/resolv.conf
```

**Contenu :**

```conf
search LIN1.local
nameserver 10.10.10.11
```

**Tester :**

```bash
nslookup SRV-LIN1-01
dig @10.10.10.11 SRV-LIN1-01.LIN1.local A
```

## Configuration de la résolution DNS (SRV-LIN1-02)

**Ouvrir le fichier :**

```bash
nano /etc/resolv.conf
```

**Contenu :**

```conf
search LIN1.local
nameserver 10.10.10.11
```

**Tester :**

```bash
nslookup SRV-LIN1-01
nslookup deb.debian.org
ping 8.8.8.8
ping deb.debian.org
```

> Selon le gestionnaire réseau installé, `/etc/resolv.conf` peut être régénéré. Vérifier sa persistance après redémarrage.

---

# CONFIGURATION SSH

## Connexion en SSH

Le SSH permet une administration distante chiffrée. Pour le POC, l’authentification par clé ED25519 est privilégiée ; la clé publique du poste client doit figurer dans `authorized_keys` sur chaque serveur.

```bash
ip a
```

### Via CMD ou PowerShell

```bash
ssh-keygen
type $env:USERPROFILE\.ssh\id_ed25519.pub
```

### Via Debian

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
nano /root/.ssh/authorized_keys

chmod 600 /root/.ssh/authorized_keys
```

### Via CMD ou PowerShell

```bash
ssh root@10.10.10.11
```

---

# INSTALLATION DE NEXTCLOUD (SRV-LIN1-02)

## Installation Apache2 (SRV-LIN1-02)

```bash
sudo apt install apache2
sudo apt install php libapache2-mod-php php-mysql php-common php-gd php-xml php-mbstring php-zip php-curl
```

## Installation MariaDB (SRV-LIN1-02)

```bash
sudo apt install mariadb-server mariadb-client
```

## Installation NextCloud (SRV-LIN1-02)

Nextcloud fournit l’accès web aux fichiers, le partage entre comptes et le calendrier. Apache sert l’application et MariaDB stocke ses données applicatives.

**Ouvrir MariaDB :**

```bash
sudo mysql -u root -p
```

**Commandes SQL à saisir dans MariaDB :**

```sql
CREATE DATABASE nextcloud;
GRANT ALL PRIVILEGES ON nextcloud.* TO 'cpnv'@'localhost' IDENTIFIED BY '<mot-de-passe-à-renseigner>';
FLUSH PRIVILEGES;
EXIT;
```

**Installer les fichiers Nextcloud :**

```bash
apt install unzip
wget https://download.nextcloud.com/server/releases/latest-34.zip
sudo unzip latest-34.zip -d /var/www/html/
sudo chown -R www-data:www-data /var/www/html/nextcloud/
```

Ensuite testez le en entrant l'adresse IP de votre machine dans un navigateur.

---

# INSTALLATION ET CONFIGURATION DU CLIENT LINUX

## Paramètres d'installation CLI-LIN1-01

Faire une installation classique comme pour les serveurs excepté qu'il ne faut pas enlever

l'interface graphique ou GNOME et ajoutez SSH comme pour les autres machines.

## Configuration DHCP (CLI-LIN1-01)

**Ouvrir le fichier réseau :**

```bash
sudo nano /etc/network/interfaces
```

**Contenu :**

```ini
auto ens33
iface ens33 inet dhcp
```

**Vérifications :**

```bash
ip -br addr
ip route
ping -c 3 10.10.10.11
ping -c 3 8.8.8.8
ping -c 3 deb.debian.org
```

Le client doit recevoir une adresse comprise entre `10.10.10.100` et `10.10.10.200`.

**Mise à jour :**

```bash
su -
apt update && apt upgrade
```

## Configuration NextCloud (CLI-LIN1-01)

Allez sur votre navigateur et entrez l'URL de votre service Nextcloud sur SRV-LIN1-02:

```
http://10.10.10.22/nextcloud
```

Ensuite créez un compte administrateur.

`admin` et mot de passe `<mot-de-passe-à-renseigner>`

Et connectez vous à la base de donnée avec vos identifiant MariaDB.

`cpnv` et mot de passe `<mot-de-passe-à-renseigner>`

---

# INSTALLATION ET CONFIGURATION LDAP (SRV-LIN1-01)

## Installation et configuration OpenLDAP (SRV-LIN1-01)

OpenLDAP centralise les identités et les groupes. LAM fournit une interface d’administration ; Nextcloud utilise ensuite l’annuaire pour authentifier `dev02`.

Installez OpenLDAP ainsi que les outils LDAP:

```bash
sudo apt install slapd ldap-utils
```

Lancez la configuration d'OpenLDAP:

```bash
sudo dpkg-reconfigure slapd
```

Configurez les paramètres suivants:

```text
Omettre la configuration d'OpenLDAP : Non
Nom de domaine DNS : LIN1.local
Nom d'entité (organisation) : LIN1
Mot de passe administrateur : [mot de passe LDAP]
```

Vérifiez que le service LDAP fonctionne:

```bash
sudo systemctl status slapd
```

Vérifiez la base LDAP:

```bash
sudo slapcat | head -5
```

Le résultat doit notamment contenir:

```text
dn: dc=LIN1,dc=local
o: LIN1
dc: LIN1
```

Vérifiez l'authentification de l'administrateur LDAP:

```bash
ldapwhoami -x -D "cn=admin,dc=LIN1,dc=local" -W
```

Le résultat doit être:

```text
dn:cn=admin,dc=LIN1,dc=local
```

## Création de la structure LDAP (SRV-LIN1-01)

Créez un fichier contenant les unités organisationnelles `People` et `Groups`:

```bash
nano /root/base.ldif
```

Ajoutez:

```text
dn: ou=People,dc=LIN1,dc=local
objectClass: organizationalUnit
ou: People

dn: ou=Groups,dc=LIN1,dc=local
objectClass: organizationalUnit
ou: Groups
```

Ajoutez les entrées à LDAP:

```bash
ldapadd -x -D "cn=admin,dc=LIN1,dc=local" -W -f /root/base.ldif
```

## Création du groupe Developpeur (SRV-LIN1-01)

Créez le fichier du groupe:

```bash
nano /root/group.ldif
```

Ajoutez:

```text
dn: cn=Developpeur,ou=Groups,dc=LIN1,dc=local
objectClass: top
objectClass: posixGroup
cn: Developpeur
gidNumber: 10000
```

Ajoutez le groupe à LDAP:

```bash
ldapadd -x -D "cn=admin,dc=LIN1,dc=local" -W -f /root/group.ldif
```

## Création de l'utilisateur dev02 (SRV-LIN1-01)

Créez le fichier de l'utilisateur:

```bash
nano /root/dev02.ldif
```

Ajoutez:

```text
dn: uid=dev02,ou=People,dc=LIN1,dc=local
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: dev02
uid: dev02
uidNumber: 10002
gidNumber: 10000
homeDirectory: /home/dev02
loginShell: /bin/bash
userPassword: <mot-de-passe-LDAP-à-renseigner>
```

Ajoutez l'utilisateur à LDAP:

```bash
ldapadd -x -D "cn=admin,dc=LIN1,dc=local" -W -f /root/dev02.ldif
```

Vérifiez que l'utilisateur existe:

```bash
ldapsearch -x -b "dc=LIN1,dc=local" "(uid=dev02)"
```

## Ajout de dev02 au groupe Developpeur (SRV-LIN1-01)

Créez le fichier de modification:

```
nano /root/add-dev02-group.ldif
```

Ajoutez:

```
dn: cn=Developpeur,ou=Groups,dc=LIN1,dc=local
changetype: modify
add: memberUid
memberUid: dev02
```

Appliquez la modification:

```bash
ldapmodify -x -D "cn=admin,dc=LIN1,dc=local" -W -f /root/add-dev02-group.ldif
```

Vérifiez l'appartenance de `dev02` au groupe:

```bash
ldapsearch -x -b "ou=Groups,dc=LIN1,dc=local" "(cn=Developpeur)"
```

Le résultat doit notamment contenir:

```text
cn: Developpeur
gidNumber: 10000
memberUid: dev02
```

## Installation et configuration de LDAP Account Manager (SRV-LIN1-01)

Mettez à jour votre serveur et ajoutez LDAP:

```bash
sudo apt update
sudo apt install ldap-account-manager
```

### Via SRV-LIN1-01

Relancez le service Apache2.

### Via CLI-LIN1-01

Allez sur le navigateur et allez sur:

```
http://10.10.10.11/lam
```

Cliquez ensuite sur `LAM configuration`.

Cliquez ensuite sur `Edit server profiles`.

Ensuite connectez-vous au compte automatique `lam` avec le mot de passe `lam`.

Modifiez `List of valid users` par:

```
cn=admin,dc=LIN1,dc=local
```

Dans `Tree suffix` mettez:

```
dc=LIN1,dc=local
```

Vous pouvez aussi si vous le voulez changer la langue et la time zone.

Puis allez dans `Account types` et modifiez la configuration par défaut dans `Users` et `Groups` par votre domaine.

Pour `Users`:

```
ou=People,dc=LIN1,dc=local
```

Pour `Groups`:

```
ou=Groups,dc=LIN1,dc=local
```

Puis sauvegardez tout en bas de la page.

Ensuite connectez vous avec votre compte administrateur LDAP et avec le mot de passe que vous aviez créé plus tôt. Vous devriez accéder à la gestion des utilisateurs LDAP.

# CONNEXION NEXTCLOUD ET LDAP (SRV-LIN-02)

```bash
sudo apt install php-ldap
sudo systemctl restart apache2
```

### Via CLI-LIN1-01

Ouvrons maintenant nextcloud depuis le navigateur web.

```bash
https://10.10.10.22/nextcloud
```

Profile -> Applications et cherchez `LDAP user and group backend` et activez le.

Ensuite Profile -> Paramètres d'administration -> Intégration LDAP/AD -> Serveur

Et entrez ces données:

```
Hôte: 10.10.10.11
Port: 389
DN utilisateur: cn=admin,dc=LIN1,dc=local
Mot de passe: <mot-de-passe-à-renseigner>
DN de base: dc=LIN1,dc=local
```

Ensuite Profile -> Paramètres d'administration -> Intégration LDAP/AD -> Utilisateurs

Et entrez ces données:

```
Seulement ces classes d'objets: posixAccount
```


Ensuite Profile -> Paramètres d'administration -> Intégration LDAP/A -> Attribut de connexion

Et entrez ces données:

```
Modifier la requête LDAP: [COCHÉ]
Modifier la requête LDAP: (&(objectClass=posixAccount)(uid=%uid))
Loginname de test: dev02
```

Test de connexion Nextcloud:

```
Utilisateur: dev02
Mot de passe: <mot-de-passe-LDAP-à-renseigner>
```

# INSTALLATION DU NAS

Le NAS OpenMediaVault héberge les données sur un miroir RAID 1 et les expose notamment par NFS, SMB et iSCSI. Le RAID améliore la disponibilité face à la panne d’un disque, mais ne remplace pas une sauvegarde.

## Paramètres d'installation NAS-LIN1-01

- Pas d'interface graphique ni de GNOME
- Ajout du service SSH
- Ajout de GRUB dans /dev/sda

## Adressage IP (NAS-LIN1-01)

**Ouvrir la configuration :**

```bash
nano /etc/network/interfaces
```

**Contenu :**

```ini
auto ens33
iface ens33 inet static
    address 10.10.10.33/24
    gateway 10.10.10.11
```

**Application et contrôle :**

```bash
ifdown ens33 2>/dev/null
ifup ens33
ip -br addr
ip route
```

## Installation de OpenMediaVault (NAS-LIN1-01)

### Via NAS-LIN1-01

```bash
nano /etc/apt/sources.list
	deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
	deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
	deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
apt update
apt install wget gnupg postfix -y
```

Lors de la configuration de Postfix, sélectionnez: `Local uniquement`

```bash
cd /root
wget https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install
chmod +x install
./install -n
apt install openmediavault-md -y
omv-salt deploy run mdadm
```

Configurez le mot de passe administrateur de l'interface OpenMediaVault: omv-firstaid
Sélectionnez: Change Workbench administrator password
Définissez le mot de passe: `<mot-de-passe-à-renseigner>`

### Via CLI-LIN1-01

Ouvrez un navigateur et accédez à: `http://10.10.10.33`

Utilisateur: admin
Mot de passe: `<mot-de-passe-à-renseigner>`

## Création du RAID1 (CLI-LIN1-01)

> **Identification du volume :** les étapes initiales mentionnent `/dev/md0`, tandis que le volume effectivement observé lors des tests de maintenance est `/dev/md127`. Vérifier avec `cat /proc/mdstat` et `mdadm --detail` avant toute commande sur le RAID. Le nom du périphérique peut varier après assemblage/redémarrage.

Stockage > Volumes RAID

Nom: RAID1
Niveau: Miroir / RAID1
Périphériques: sdb et sdc

## Création du système de fichiers (CLI-LIN1-01)

Stockage > Systèmes de fichiers

Périphérique: /dev/md0
Type: EXT4
Étiquette: DATA
Seuil d'avertissement d'utilisation: 85%

## Création du dossier partagé (CLI-LIN1-01)

Stockage > Dossiers partagés

```bash
Nom: DATA
Système de fichiers: /dev/md0 [DATA]
Chemin relatif: DATA/
```

## Configuration NFS (CLI-LIN1-01)

Services > NFS > Paramètres

Cochez: Activé

Services > NFS > Partages

```bash
Dossier partagé: DATA [on /dev/md0, DATA/]
Client: 10.10.10.0/24
Permissions: Lecture/Écriture
```

### Via NAS-LIN1-01

```bash
omv-salt deploy run nfs
```

## Montage NFS sur SRV-LIN1-02

### Via SRV-LIN1-02

Installez le client NFS:

```bash
apt update
apt install nfs-common -y
showmount -e 10.10.10.33
mkdir -p /mnt/NAS-DATA
mount -t nfs 10.10.10.33:/export/DATA /mnt/NAS-DATA
touch /mnt/NAS-DATA/test.txt
ls -l /mnt/NAS-DATA
```

## Montage NFS permanent (SRV-LIN1-02)

> **CONFIGURATION HISTORIQUE - NE PAS RÉUTILISER TELLE QUELLE.** Le montage ci-dessous a été remplacé par la version opérationnelle `vers=3,_netdev,nofail`, présentée dans « Correction et persistance du partage NFS ». Lors d'une installation neuve, utiliser directement cette configuration finale.

> **Historique :** la configuration ci-dessous est la première version. La configuration finale opérationnelle, avec `vers=3,_netdev,nofail`, est décrite plus bas dans « Correction et persistance du partage NFS ». Ne pas conserver deux entrées concurrentes pour le même point de montage dans `/etc/fstab`.

### Via SRV-LIN1-02

Ouvrez:

```bash
nano /etc/fstab
```

Ajoutez:

```bash
10.10.10.33:/export/DATA /mnt/NAS-DATA nfs defaults,_netdev 0 0
```

Rechargez la configuration et testez:

```bash
systemctl daemon-reload
umount /mnt/NAS-DATA
mount -a
mount | grep NAS-DATA
```

Le partage doit être automatiquement remonté dans `/mnt/NAS-DATA`.

## Configuration iSCSI (NAS-LIN1-01)

### Via NAS-LIN1-01

Installez targetcli:

```bash
apt update
apt install targetcli-fb -y
```

Créez un dossier destiné au stockage iSCSI sur le RAID1:

```bash
mkdir -p /srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257/iscsi
```

Créez un disque virtuel iSCSI de 2 Go:

```bash
fallocate -l 2G /srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257/iscsi/disk01.img
ls -lh /srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257/iscsi/
targetcli
/backstores/fileio create disk01 /srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257/iscsi/disk01.img 2G
/iscsi create iqn.2026-10.local.lin1:nas-lin1-01
/iscsi/iqn.2026-10.local.lin1:nas-lin1-01/tpg1/luns create /backstores/fileio/disk01
```

```bash
Target: iqn.2026-10.local.lin1:nas-lin1-01
LUN: disk01
Port: 3260
```

```bash
saveconfig
exit
systemctl enable --now rtslib-fb-targetctl
ss -lnt | grep 3260
```

Le port `3260` doit apparaître en écoute.

## Connexion iSCSI depuis SRV-LIN1-02

### Via SRV-LIN1-02

```bash
apt update
apt install open-iscsi -y
systemctl enable --now iscsid
iscsiadm -m discovery -t sendtargets -p 10.10.10.33
```

Résultat attendu : `10.10.10.33:3260,1 iqn.2026-10.local.lin1:nas-lin1-01`

Connexion à la cible :

```bash
iscsiadm -m node -T iqn.2026-10.local.lin1:nas-lin1-01 -p 10.10.10.33:3260 --login
lsblk
```

Résultat attendu : `0`

Formatage et montage du disque iSCSI :

```bash
# ATTENTION : le formatage détruit les données du disque ciblé !
# Identifier le disque iSCSI avec lsblk -f et iscsiadm -m session.
# Vérifier impérativement que /dev/sdb n'est PAS le disque système.
lsblk -f
iscsiadm -m session
# À exécuter uniquement si /dev/sdb est bien le NOUVEAU disque iSCSI :
mkfs.ext4 /dev/sdb
mkdir -p /mnt/ISCSI
mount /dev/sdb /mnt/ISCSI
touch /mnt/ISCSI/test-iscsi.txt
ls -l /mnt/ISCSI
iscsiadm -m node -T iqn.2026-10.local.lin1:nas-lin1-01 -p 10.10.10.33:3260 --op update -n node.startup -v automatic
iscsiadm -m node -o show | grep node.startup
```

Résultat attendu : `node.startup = automatic`

```bash
blkid /dev/sdb
```

Récupérez l'UUID et et ajoutez le dans le fstab:

```bash
nano /etc/fstab
```

**Ajouter dans `/etc/fstab` l'UUID réel obtenu avec `blkid` (celui-ci est un exemple du laboratoire) :**

```fstab
UUID=92209986-8a49-4ba2-81bb-4d012f4f3309 /mnt/ISCSI ext4 _netdev,nofail 0 2
```

**Appliquer et vérifier :**

```bash
umount /mnt/ISCSI
systemctl daemon-reload
mount -a
mount | grep ISCSI
ls -l /mnt/ISCSI
```

On devrait retrouver `test-iscsi.txt`.

### Via CLI-LIN1-01

Vérification de la connectivité avec le NAS :

```bash
ping -c 4 10.10.10.33
```

## Création du partage SMB

 OpenMediaVault : Services > SMB/CIFS > Settings.

```text
Activé : Oui
Workgroup : WORKGROUP
```

Enregistrez et appliquez les modifications.

Services > SMB/CIFS > Shares

```text
Activé : Oui
Dossier partagé : DATA
Public : Invités autorisés
Lecture seule : Non
Navigable : Oui
Cacher les fichiers systèmes : Oui
Suivre les liens symboliques : Oui
Attributs étendus : Oui
```

Enregistrez et appliquez les modifications.

## Application de la configuration SMB

### Via NAS-LIN1-01

```bash
omv-salt deploy run samba
systemctl status smbd --no-pager
```

Service smbd: `active (running)`

## Test du partage SMB

### Via CLI-LIN1-01

```bash
apt update
apt install smbclient cifs-utils -y
smbclient -L //10.10.10.33 -N
smbclient //10.10.10.33/DATA -N
```

```text
mkdir test-smb
ls
```

Le dossier test-smb doit apparaître.

```text
exit
```

## Configuration HTTPS de Nextcloud (SRV-LIN1-02)

### Via SRV-LIN1-02

```bash
a2enmod ssl
systemctl restart apache2
apache2ctl -M | grep ssl
a2ensite default-ssl
systemctl reload apache2
```

### Via CLI-LIN1-01

Ouvrez dans le navigateur :

```text
https://10.10.10.22/nextcloud
```

Acceptez l'avertissement du certificat autosigné dans l'environnement de laboratoire. Connectez-vous à Nextcloud et vérifiez l'accès aux fichiers.

## Correction et persistance du partage NFS

> **CONFIGURATION FINALE UTILISÉE POUR LE POC.** Cette section remplace le montage NFS initial. Dans `/etc/fstab` de SRV-LIN1-02, conserver une seule ligne pour `/mnt/NAS-DATA` : celle avec `vers=3,_netdev,nofail`.

**Machines : NAS-LIN1-01 et SRV-LIN1-02**

Après un redémarrage des machines virtuelles, le partage NFS ne fonctionnait plus correctement.

Nous avons constaté que le répertoire `/export/DATA` du NAS ne pointait plus vers le dossier situé sur le volume RAID.

### Rétablissement du montage sur le NAS

**Machine : NAS-LIN1-01**

```
mount --bind /srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257/DATA /export/DATA
```

Ce montage permet de rendre le contenu du dossier `DATA`, situé sur le RAID, accessible par NFS.

### Montage automatique au démarrage

Modification du fichier :

```
nano /etc/fstab
```

Ajout de la ligne :

```
/srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257/DATA /export/DATA none bind,nofail 0 0
```

Application et vérification :

```
systemctl daemon-reload
mount -a
findmnt /export/DATA
```

Le montage pointe désormais vers le volume RAID.

### Actualisation des exports NFS

```
exportfs -ra
exportfs -v
```

Le partage `/export/DATA` est exporté en lecture et écriture pour le réseau `10.10.10.0/24`.

### Montage NFS sur SRV-LIN1-02

Le montage a fonctionné en utilisant explicitement NFS version 3.

```
mount -t nfs -o vers=3 10.10.10.33:/export/DATA /mnt/NAS-DATA
```

Pour rendre le montage persistant, modification du fichier :

```
nano /etc/fstab
```

Ajout :

```
10.10.10.33:/export/DATA /mnt/NAS-DATA nfs vers=3,_netdev,nofail 0 0
```

Après modification, contrôler avec `findmnt /mnt/NAS-DATA` et `mount -a`. Vérifier qu'aucune deuxième entrée `/mnt/NAS-DATA` ne subsiste dans `/etc/fstab`.

### Test des permissions

Nous avons vérifié que le service web Apache pouvait écrire sur le partage :

```
sudo -u www-data touch /mnt/NAS-DATA/test-nextcloud.txt
```

**Résultat :** création du fichier réussie.

Le partage NFS est donc accessible en écriture par le service Nextcloud.

---

## Connexion du stockage NAS à Nextcloud

**Machine : SRV-LIN1-02**

Nous avons activé l'application **External storage support** dans Nextcloud.

### Configuration

Depuis le compte administrateur `cpnv` :

- Ouvrir les paramètres d'administration.
    
- Aller dans **Stockages externes**.
    
- Ajouter un stockage de type **Local**.
    
- Configurer les paramètres suivants :
    

|Paramètre|Valeur|
|---|---|
|Nom du montage|NAS-DATA|
|Type|Local|
|Chemin|`/mnt/NAS-DATA`|
|Authentification|Aucune|

Le stockage apparaît ensuite dans la section **Fichiers** de Nextcloud sous le nom `NAS-DATA`.

### Vérification

Nous avons créé un fichier `test.txt` depuis l'interface Nextcloud.

Nous avons ensuite vérifié sa présence sur le NAS, dans le dossier correspondant au partage NFS.

**Résultat :** le fichier créé depuis Nextcloud était présent sur le NAS.

Cela confirme que Nextcloud utilise bien le stockage du NAS.

---

## Création des dossiers de travail

**Machine : NAS-LIN1-01**

Nous avons créé trois dossiers sur le stockage partagé :

- `perso`
    
- `logiciels`
    
- `commun`
    

### Commande

```
mkdir -p /export/DATA/{perso,logiciels,commun}
```

Ces dossiers servent à organiser les fichiers des utilisateurs dans Nextcloud.

---

## Configuration des ACL sur le NAS

**Machine : NAS-LIN1-01**

Afin de permettre à Nextcloud d'écrire dans les dossiers du NAS, nous avons configuré des ACL pour l'utilisateur système `www-data`, dont l'UID est `33`.

### Installation des outils ACL

```
apt install acl -y
```

### Permissions du dossier commun

```
setfacl -m u:33:rwx /export/DATA/commun
setfacl -m d:u:33:rwx /export/DATA/commun
```

### Permissions du dossier perso

```
setfacl -m u:33:rwx /export/DATA/perso
setfacl -m d:u:33:rwx /export/DATA/perso
```

### Permissions du dossier logiciels

```
setfacl -m u:33:rwx /export/DATA/logiciels
setfacl -m d:u:33:rwx /export/DATA/logiciels
```

Les ACL par défaut permettent aux nouveaux éléments de bénéficier également des permissions nécessaires.

### Vérification des ACL

```
getfacl /export/DATA/commun
getfacl /export/DATA/perso
getfacl /export/DATA/logiciels
```

### Test depuis le serveur Nextcloud

**Machine : SRV-LIN1-02**

```
sudo -u www-data touch /mnt/NAS-DATA/commun/test-acl.txt
sudo -u www-data touch /mnt/NAS-DATA/perso/test-acl.txt
sudo -u www-data touch /mnt/NAS-DATA/logiciels/test-acl.txt
```

**Résultat :** les trois fichiers ont été créés avec succès.

**Attention :** ces ACL autorisent le service Nextcloud à écrire sur le NAS. Elles ne constituent pas à elles seules une restriction individuelle des utilisateurs Nextcloud. Les droits de partage et la visibilité des dossiers doivent être gérés séparément.

---

## Configuration des utilisateurs Nextcloud

**Machine : SRV-LIN1-02**

Nous avons configuré les utilisateurs nécessaires au POC.

|Utilisateur|Type de compte|Rôle|
|---|---|---|
|cpnv|Local|Administrateur|
|dev01|Local|Développeur|
|dev02|LDAP|Développeur|
|ing01|Local|Ingénieur|
|man01|Local|Manager|

Le compte `dev02` est issu de l'annuaire LDAP configuré sur **SRV-LIN1-01**.

Nous avons vérifié qu'il pouvait se connecter à Nextcloud avec ses identifiants LDAP.

---

## Activation du partage des dossiers NAS

**Machine : SRV-LIN1-02**

Initialement, Nextcloud empêchait le repartage des dossiers du stockage externe.

Pour résoudre ce problème :

- Se connecter avec le compte administrateur `cpnv`.
    
- Ouvrir **Paramètres d'administration > Stockages externes**.
    
- Modifier les options de montage de `NAS-DATA`.
    
- Activer l'option autorisant le partage.
    

Après cette modification, les dossiers du NAS pouvaient être partagés avec d'autres utilisateurs Nextcloud.

---

## Partage des dossiers entre utilisateurs

**Machine : CLI-LIN1-01**

Depuis l'interface web de Nextcloud, avec le compte `cpnv`, nous avons configuré les partages suivants.

|Dossier|Utilisateur|Permission|
|---|---|---|
|commun|dev01|Modification autorisée|
|commun|man01|Modification autorisée|
|commun|dev02|Modification autorisée|
|logiciels|dev02|Modification autorisée|
|perso|dev02|Modification autorisée|

### Procédure de partage

- Ouvrir **Fichiers > NAS-DATA**.
    
- Sélectionner le dossier à partager.
    
- Cliquer sur **Partager**.
    
- Rechercher l'utilisateur.
    
- Activer **Autoriser la modification**.
    
- Enregistrer le partage.
    

### Test avec dev01

Nous nous sommes connectés à Nextcloud avec `dev01`.

Dans le dossier `commun`, nous avons créé un fichier :

```
test.txt
```

**Résultat :** création réussie.

### Test avec man01

Nous nous sommes ensuite connectés avec `man01`.

Nous avons ouvert le fichier `test.txt` dans `commun` et modifié son contenu.

**Résultat :** modification réussie.

Cela confirme que le partage permet à plusieurs utilisateurs de travailler sur le même fichier.

### Test avec dev02

Nous avons ouvert une session Nextcloud avec le compte LDAP `dev02`.

Les trois dossiers suivants étaient visibles :

```
perso
logiciels
commun
```

Nous avons ensuite créé le fichier :

```
commun/test-dev02.txt
```

**Résultat :** création réussie.

La connexion LDAP, la visibilité des trois dossiers et l'écriture dans `commun` ont été vérifiées. Les droits d'écriture dans `perso` et `logiciels` restent à tester individuellement.

---

## Configuration des quotas Nextcloud

**Machine : SRV-LIN1-02**

Depuis le compte administrateur `cpnv`, nous avons ouvert :

**Paramètres > Comptes**

Nous avons utilisé le bouton de modification de chaque compte pour définir les quotas.

|Utilisateur|Quota|
|---|---|
|dev01|1 Go|
|dev02|1 Go|
|ing01|1 Go|
|man01|1 Go|

Ces valeurs ont été choisies pour la démonstration du POC.

**Important :** les quotas définis dans Nextcloud ne garantissent pas la limitation de l'espace utilisé sur un stockage externe comme `NAS-DATA`. Un quota système est configuré séparément sur le NAS pour les fichiers appartenant à `www-data`.

---

## Installation et configuration du client Windows

**Machine : WIN-LIN1-01**

La machine virtuelle Windows 11 a été installée dans VMware Workstation avec les paramètres suivants :

|Paramètre|Valeur|
|---|---|
|Système|Windows 11 Pro|
|Disque|64 Go|
|RAM|4 Go|
|Processeur|2 cœurs|
|Réseau|Host-Only|
|Nom|WIN-LIN1-01|

### Vérification DHCP

Depuis l'invite de commandes Windows :

```
ipconfig /all
```

La machine a reçu automatiquement l'adresse IP `10.10.10.106` depuis le serveur DHCP de SRV-LIN1-01.

La passerelle et le serveur DNS sont configurés sur `10.10.10.11`.

### Vérification de la connectivité

```
ping 10.10.10.11
ping 10.10.10.22
```

**Résultat :** la communication avec les serveurs LIN1 fonctionne.

## Installation du client Nextcloud Windows

**Machine : WIN-LIN1-01**

Le client de synchronisation Nextcloud a été installé sur Windows 11.

### Connexion au serveur

Adresse du serveur :

```
https://10.10.10.22/nextcloud
```

Compte utilisé :

```
ing01
```

Le certificat HTTPS étant autosigné, un avertissement de sécurité peut apparaître.

Le compte `ing01` a été connecté au client Nextcloud.

### Configuration de la synchronisation

Le dossier local utilisé est :

```
C:\Users\admin\Nextcloud
```

Les dossiers `commun` et `logiciels` ont été synchronisés avec le serveur.

### Test de synchronisation du serveur vers Windows

Le fichier `test.txt`, créé précédemment dans le dossier partagé `commun`, a été synchronisé sur Windows.

**Résultat :** le fichier était présent dans le dossier local Nextcloud.

### Test de synchronisation de Windows vers le serveur

Depuis l'explorateur Windows, nous avons créé le fichier :

```
C:\Users\admin\Nextcloud\logiciels\local.txt
```

Nous avons ensuite ouvert Nextcloud depuis un navigateur pour vérifier la présence du fichier.

**Résultat :** `local.txt` était visible sur le serveur Nextcloud dans le dossier `logiciels`.

Ces tests confirment le fonctionnement de la synchronisation bidirectionnelle.

---

## Vérifications SSH et DNS depuis les clients

### Vérification SSH depuis Windows

**Machine : WIN-LIN1-01**

Une clé SSH de type ED25519 a été générée depuis Windows :

```
ssh-keygen -t ed25519
```

La clé publique a été ajoutée dans le fichier suivant sur les deux serveurs Debian :

```
/root/.ssh/authorized_keys
```

Les permissions ont été configurées :

```
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
```

### Test de connexion

Depuis Windows :

```
ssh root@10.10.10.11
ssh root@10.10.10.22
```

**Résultat :** les connexions SSH par clé publique ont fonctionné sur les deux serveurs.

### Vérification DNS

**Machine : SRV-LIN1-02**

```
nslookup SRV-LIN1-01.LIN1.local 10.10.10.11
ping -c 3 google.com
```

**Résultat :** le nom DNS `SRV-LIN1-01.LIN1.local` a été résolu vers `10.10.10.11`, et la connectivité Internet a été vérifiée.

---

## Configuration du calendrier Nextcloud

**Machine : CLI-LIN1-01**

### Activation de l'application

Depuis le compte administrateur Nextcloud, l'application **Calendar** a été installée et activée.

Version installée lors des tests : `6.6.3`.

### Création d'un événement

Nous nous sommes connectés à Nextcloud avec l'utilisateur `dev01`.

Dans l'application Calendrier, nous avons créé un événement nommé :

```
Réunion LIN1
```

**Résultat :** l'événement a été créé et affiché dans le calendrier de `dev01`.

---

## Simulation de panne et reconstruction du RAID 1

**Machine : NAS-LIN1-01**

Le NAS dispose d'un RAID 1 constitué de deux disques de données.

Le volume RAID est identifié par :

```
/dev/md127
```

### Vérification avant panne

```
cat /proc/mdstat
mdadm --detail /dev/md127
```

Un RAID 1 opérationnel affiche deux disques actifs :

```
[UU]
```

### Simulation de panne

Nous avons simulé la défaillance du disque `/dev/sdc` :

```
mdadm /dev/md127 --fail /dev/sdc
```

### Vérification du mode dégradé

```
cat /proc/mdstat
mdadm --detail /dev/md127
```

Le RAID fonctionne alors en mode dégradé, avec un seul disque actif.

Les données restent accessibles grâce au mirroring du RAID 1.

### Retrait du disque défaillant

```
mdadm /dev/md127 --remove /dev/sdc
```

### Réintégration du disque

```
mdadm /dev/md127 --add /dev/sdc
```

### Suivi de la reconstruction

```
watch -n 2 cat /proc/mdstat
```

La reconstruction est suivie jusqu'à sa fin.

### Vérification finale

```
cat /proc/mdstat
mdadm --detail /dev/md127
```

**Résultat :** le RAID est revenu à son état normal avec deux disques actifs :

```
[UU]
```

La simulation confirme que le RAID 1 permet de conserver l'accès aux données malgré la panne d'un disque et de reconstruire le miroir après réintégration.

---

## Configuration des quotas sur le NAS

**Machine : NAS-LIN1-01**

Les quotas ont été activés sur le système de fichiers du RAID afin de permettre la limitation de l'espace disque utilisé.

### Vérification de l'activation

```
quotaon -p /srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257
```

Les quotas utilisateurs et groupes sont activés.

### Vérification des limites initiales

```
repquota -aug
```

La première vérification affichait des limites `soft` et `hard` à `0`, ce qui signifie qu'aucune limite n'avait encore été définie.

### Configuration du quota www-data

```
setquota -u www-data 512000 614400 0 0 /srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257
```

|Paramètre|Valeur|
|---|---|
|Utilisateur système|www-data|
|Limite souple|500 Mio|
|Limite stricte|600 Mio|
|Nombre de fichiers|Illimité|

### Vérification

```
repquota -u /srv/dev-disk-by-uuid-379d54bf-4ea9-4b04-90fe-2b75fbbc8257
```

Les limites configurées sont :

```
soft : 512000
hard : 614400
```

**Remarque :** ce quota concerne les fichiers appartenant à l'utilisateur système `www-data`. Il ne représente pas une limite individuelle pour chaque utilisateur Nextcloud. Les quotas de 1 Go des utilisateurs Nextcloud sont configurés séparément.

---

# DÉPANNAGE

## Connexion SSH par clé refusée sur SRV-LIN1-02

**Symptôme :** `ssh root@10.10.10.22` renvoie `Permission denied (publickey,password)` malgré un mot de passe connu.

**Diagnostic :** sur le serveur, `sshd -T` indiquait `permitrootlogin without-password`, donc la connexion `root` par mot de passe était interdite. Depuis Windows, `ssh -v root@10.10.10.22` montrait que la clé `id_ed25519` était proposée mais non acceptée.

```powershell
# Windows : empreinte de la clé publique utilisée
ssh-keygen -lf "$env:USERPROFILE\.ssh\id_ed25519.pub"
# Windows : afficher la clé publique (jamais la clé privée)
type "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

```bash
# Console VMware de SRV-LIN1-02 : comparer les clés autorisées
ssh-keygen -lf /root/.ssh/authorized_keys
ls -ld /root/.ssh
ls -l /root/.ssh/authorized_keys
```

**Correction réalisée :** ajouter la clé **publique** du poste Windows dans `/root/.ssh/authorized_keys`, sur une ligne distincte, en conservant les clés existantes ; puis vérifier les permissions :

```bash
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
```

**Validation :** `ssh root@10.10.10.22` depuis Windows fonctionne par clé. Ne jamais copier ni publier la clé privée.

## Partage NFS absent après redémarrage

**Symptôme :** `/mnt/NAS-DATA` ne donne plus accès aux fichiers attendus.

**Cause rencontrée :** `/export/DATA` sur le NAS ne pointait plus vers le dossier du volume RAID. Le montage NFS a également nécessité l'option `vers=3` dans cet environnement.

```bash
# NAS-LIN1-01
findmnt /export/DATA
exportfs -v
cat /proc/mdstat

# SRV-LIN1-02
findmnt /mnt/NAS-DATA
showmount -e 10.10.10.33
mount | grep NAS-DATA
```

**Correction documentée :** le montage bind persistant sur le NAS et l'entrée NFS `vers=3,_netdev,nofail` sur SRV2 sont détaillés dans « Correction et persistance du partage NFS ». Après correction, vérifier l'écriture avec `sudo -u www-data touch /mnt/NAS-DATA/test-nextcloud.txt`.

## Nextcloud ne peut pas écrire sur le NAS

Vérifier d'abord le montage NFS et les droits du compte de service, puis les ACL :

```bash
# NAS-LIN1-01
getfacl /export/DATA/commun
getfacl /export/DATA/perso
getfacl /export/DATA/logiciels

# SRV-LIN1-02
findmnt /mnt/NAS-DATA
sudo -u www-data test -w /mnt/NAS-DATA/commun && echo 'Écriture autorisée'
```

Les ACL de l'UID `33` concernent le processus `www-data`. Les droits visibles par `dev01`, `dev02` et les autres comptes se règlent aussi dans les partages Nextcloud.

## Vérification DNS et DHCP

```bash
# SRV-LIN1-01
systemctl status bind9 --no-pager
named-checkconf
named-checkzone LIN1.local /var/cache/bind/db.LIN1.local
systemctl status isc-dhcp-server --no-pager
journalctl -u isc-dhcp-server -n 30 --no-pager

# Client Linux
ip -br addr
ip route
nslookup SRV-LIN1-01.LIN1.local 10.10.10.11
```

Si un test échoue, contrôler la configuration des interfaces, la connectivité vers `10.10.10.11`, les services concernés et les journaux avant de modifier quoi que ce soit.

---

# MAINTENANCE

## Contrôle des services

```bash
# SRV-LIN1-01
systemctl status bind9 isc-dhcp-server slapd --no-pager

# SRV-LIN1-02
systemctl status apache2 mariadb --no-pager
findmnt /mnt/NAS-DATA
findmnt /mnt/ISCSI
lsblk -f
iscsiadm -m session

# NAS-LIN1-01
cat /proc/mdstat
mdadm --detail /dev/md127
systemctl status smbd --no-pager
exportfs -v
repquota -aug
```

## Journaux et contrôles après redémarrage

```bash
journalctl -p err -b --no-pager
systemctl --failed
ip -br addr
ip route
```

Après un redémarrage, contrôler en priorité les adresses IP, DNS, montages NFS/iSCSI, disponibilité de Nextcloud et état du RAID `[UU]`.

## Sauvegarde et restauration

Conserver des copies hors du NAS des fichiers de configuration essentiels : `/etc/network/interfaces`, `/etc/bind/`, `/etc/dhcp/dhcpd.conf`, paramètres LDAP, configuration Apache/Nextcloud, base de données MariaDB et configuration des exports NAS. Une restauration complète doit être testée séparément : les archives OVA ne remplacent pas à elles seules une stratégie de sauvegarde des données.

Avant toute simulation de panne RAID, identifier précisément le périphérique avec `mdadm --detail` et disposer d'une sauvegarde. Ne pas lancer `mkfs`, `mdadm --create` ou un repartitionnement pendant une simple maintenance.

---

# BONNES PRATIQUES ET SÉCURITÉ

- **SSH :** privilégier les clés ED25519, protéger les clés privées et limiter l'accès SSH de `root` lorsque c'est possible. Ne pas désactiver les protections d'authentification pour contourner une erreur de clé.
- **Identifiants :** ne pas publier de mots de passe réels ni de secrets LDAP/MariaDB dans GitHub ou les scripts. Utiliser des variables ou des invites sécurisées.
- **HTTPS :** le certificat autosigné utilisé ici convient aux tests du laboratoire, mais produit un avertissement de confiance ; en production, utiliser un certificat validé et un nom DNS approprié.
- **DNS :** la désactivation de `dnssec-validation` est un choix du laboratoire à réévaluer avant un déploiement réel.
- **SMB :** l'accès invité en écriture configuré pour le POC doit être remplacé par des accès authentifiés et restreints en production.
- **LDAP :** les échanges simples sur le port `389` ne sont pas chiffrés par défaut ; privilégier TLS/StartTLS ou LDAPS hors laboratoire.
- **Stockage :** vérifier les droits NFS/ACL, limiter les exports au réseau nécessaire et sauvegarder les données indépendamment du RAID.
- **Scripts :** tester sur des VM neuves avec snapshots, vérifier les erreurs, et éviter les opérations destructrices sur une installation existante.

---

# LIMITES TECHNIQUES ET AVERTISSEMENTS

- Le **RAID 1** maintient les données disponibles si un disque tombe en panne, mais ne protège ni des suppressions accidentelles ni d'une corruption propagée aux deux disques.
- Les **quotas Nextcloud de 1 Go** ne garantissent pas la limitation de l'espace du stockage externe `NAS-DATA`. Le quota système `www-data` de 500 Mio (souple) / 600 Mio (strict) s'applique aux fichiers possédés par ce compte, pas à chaque utilisateur Nextcloud.
- Les **ACL système de `www-data`** autorisent le service à écrire ; elles ne prouvent pas à elles seules les permissions individuelles de `dev01` ou `dev02`. Vérifier les partages dans Nextcloud et tester séparément les dossiers `perso`, `logiciels` et `commun`.
- La **reconstruction RAID** peut prendre plus longtemps que la durée de la démonstration ; suivre son avancement et vérifier le retour à `[UU]`.
- Le **nom du périphérique RAID** peut être `/dev/md0` lors de la création et `/dev/md127` après assemblage ; toujours identifier le volume réellement actif avant une commande.
- La configuration **NFS initiale** est conservée dans la chronologie de réalisation, mais la version corrigée avec NFSv3 est celle utilisée pour les vérifications finales.
- Les adresses IP, noms d'interfaces et chemins UUID présentés sont propres à ce laboratoire ; ils doivent être adaptés à une autre infrastructure.
