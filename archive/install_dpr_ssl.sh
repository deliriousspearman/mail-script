#!/usr/bin/env bash
#
# setup_mail_virtual_with_roundcube_cert_choice.sh
#
# Installs Postfix + Dovecot with virtual mailboxes, prompts user for
# self-signed or existing certificate, optionally installs Roundcube (SQLite),
# and now prompts to add domain to /etc/hosts at 127.0.0.1.
#
# NOTE: This is a demonstration script, not production-hardened.
# Run as root or with sudo.

set -e

######################################
# 1) Root check
######################################
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root. Aborting."
  exit 1
fi

######################################
# 2) Basic Configuration Variables
######################################
MAIL_DOMAIN="example.com"
MAIL_HOSTNAME="mail.example.com"
POSTMASTER_ADDRESS="postmaster@example.com"

VMAIL_USER="test@example.com"
VMAIL_PASS="MySecurePassword"  # The script will generate a Dovecot-compatible hash

VMAIL_DIR="/var/mail/vhosts"
VMAIL_USERID="5000"
VMAIL_GROUPID="5000"

# Default SSL info if self-signed
SSL_COUNTRY="US"
SSL_STATE="NewYork"
SSL_LOCALITY="NewYorkCity"
SSL_ORG="ExampleInc"
SSL_OU="IT"
SSL_CN="${MAIL_HOSTNAME}"

DOVECOT_USERS="/etc/dovecot/users"
VMAILBOX="/etc/postfix/vmailbox"

# Paths for cert/key
CERT_FILE="/etc/ssl/certs/${MAIL_HOSTNAME}.pem"
KEY_FILE="/etc/ssl/private/${MAIL_HOSTNAME}.key"

# Flag to indicate if Roundcube should ignore cert validation
IGNORE_CERT_VALIDATION_IN_ROUNDCUBE="false"

######################################
# 3) Prompt: Add domain to /etc/hosts?
######################################
read -rp "Would you like to add '${MAIL_HOSTNAME}' to /etc/hosts at 127.0.0.1? [y/N]: " ADD_HOSTS
if [[ "${ADD_HOSTS,,}" == "y" ]]; then
  # Check if /etc/hosts already has the MAIL_HOSTNAME
  if grep -q "127.0.0.1.*${MAIL_HOSTNAME}" /etc/hosts; then
    echo "'${MAIL_HOSTNAME}' is already in /etc/hosts. Skipping..."
  else
    echo "Adding '${MAIL_HOSTNAME}' to /etc/hosts for 127.0.0.1..."
    echo "127.0.0.1   ${MAIL_HOSTNAME}" >> /etc/hosts
  fi
fi

######################################
# 4) Install dependencies for Postfix & Dovecot
######################################
echo "=== Installing Postfix & Dovecot ==="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  postfix \
  dovecot-core dovecot-imapd dovecot-pop3d \
  openssl

######################################
# 5) Create 'vmail' user/group
######################################
if ! getent group vmail >/dev/null; then
  groupadd -g "${VMAIL_GROUPID}" vmail
fi
if ! getent passwd vmail >/dev/null; then
  useradd -g vmail -u "${VMAIL_USERID}" vmail -d "${VMAIL_DIR}" -m
fi

mkdir -p "${VMAIL_DIR}"
chown -R vmail:vmail "${VMAIL_DIR}"
chmod -R 770 "${VMAIL_DIR}"

######################################
# 6) Prompt: Generate self-signed or import existing certificate?
######################################
echo
echo "How would you like to configure the SSL certificate for Postfix & Dovecot?"
echo "1) Generate a self-signed certificate"
echo "2) Import an existing certificate/key from disk"
read -rp "Choose an option [1-2]: " CERT_OPTION

case "$CERT_OPTION" in
  1)
    echo "=== Generating self-signed SSL certificate (TEST ONLY) ==="
    mkdir -p /etc/ssl/private
    openssl req -new -x509 -days 365 -nodes \
      -subj "/C=${SSL_COUNTRY}/ST=${SSL_STATE}/L=${SSL_LOCALITY}/O=${SSL_ORG}/OU=${SSL_OU}/CN=${SSL_CN}" \
      -keyout "${KEY_FILE}" \
      -out "${CERT_FILE}"
    chmod o= "${KEY_FILE}"
    # Mark that we should ignore certificate validation in Roundcube
    IGNORE_CERT_VALIDATION_IN_ROUNDCUBE="true"
    ;;
  2)
    echo "=== Importing existing certificate ==="
    read -rp "Enter path to the certificate file (.pem): " SRC_CERT
    read -rp "Enter path to the private key file (.key): " SRC_KEY

    if [ ! -f "$SRC_CERT" ] || [ ! -f "$SRC_KEY" ]; then
      echo "ERROR: One or both files do not exist. Aborting."
      exit 1
    fi

    mkdir -p /etc/ssl/private
    cp "$SRC_CERT" "${CERT_FILE}"
    cp "$SRC_KEY"  "${KEY_FILE}"
    chmod o= "${KEY_FILE}"
    ;;
  *)
    echo "Invalid choice. Aborting."
    exit 1
    ;;
esac

######################################
# 7) Configure Postfix
######################################
echo "=== Configuring Postfix ==="
cp /etc/postfix/main.cf /etc/postfix/main.cf.bak."$(date +%F-%T)"

postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
postconf -e "mydestination = localhost, localhost.localdomain, \$myhostname"
postconf -e "mynetworks_style = host"
postconf -e "smtpd_banner = \$myhostname ESMTP \$mail_name (Ubuntu)"
postconf -e "biff = no"

# TLS
postconf -e "smtpd_use_tls=yes"
postconf -e "smtpd_tls_auth_only=yes"
postconf -e "smtpd_tls_security_level=may"
postconf -e "smtpd_tls_cert_file=${CERT_FILE}"
postconf -e "smtpd_tls_key_file=${KEY_FILE}"
postconf -e "smtp_tls_security_level=may"
postconf -e "smtp_tls_loglevel=1"

# Virtual mail settings
postconf -e "virtual_mailbox_domains = ${MAIL_DOMAIN}"
postconf -e "virtual_mailbox_base = ${VMAIL_DIR}"
postconf -e "virtual_mailbox_maps = hash:${VMAILBOX}"
postconf -e "virtual_minimum_uid = 100"
postconf -e "virtual_uid_maps = static:${VMAIL_USERID}"
postconf -e "virtual_gid_maps = static:${VMAIL_GROUPID}"

# Use Dovecot for SASL
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_sasl_tls_security_options = noanonymous"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"

# Aliases
postconf -e "alias_maps = hash:/etc/aliases"
postconf -e "alias_database = hash:/etc/aliases"
sed -i "/^postmaster:/d" /etc/aliases
echo "postmaster: ${POSTMASTER_ADDRESS}" >> /etc/aliases
newaliases

# /etc/postfix/vmailbox
cat > "${VMAILBOX}" <<EOF
${VMAIL_USER}   ${MAIL_DOMAIN}/test/
EOF
postmap "${VMAILBOX}"

######################################
# 8) Configure Dovecot
######################################
echo "=== Configuring Dovecot ==="
cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-mail.conf /etc/dovecot/conf.d/10-mail.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-auth.conf /etc/dovecot/conf.d/10-auth.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-master.conf /etc/dovecot/conf.d/10-master.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-ssl.conf /etc/dovecot/conf.d/10-ssl.conf.bak."$(date +%F-%T)"

# Listen on all interfaces
sed -i "s|^#listen = \*, ::|listen = \*, ::|" /etc/dovecot/dovecot.conf

# Mail location
sed -i "s|^#mail_location = .*|mail_location = maildir:${VMAIL_DIR}/%d/%n/Maildir|" /etc/dovecot/conf.d/10-mail.conf

# Allow plaintext over TLS
sed -i "s|^#disable_plaintext_auth = yes|disable_plaintext_auth = no|" /etc/dovecot/conf.d/10-auth.conf

# Disable system auth, enable passwd-file
sed -i "s/^!include auth-system.conf.ext/#!include auth-system.conf.ext/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/^#!include auth-passwdfile.conf.ext/!include auth-passwdfile.conf.ext/" /etc/dovecot/conf.d/10-auth.conf

# Create passwd-file config
cat > /etc/dovecot/conf.d/auth-passwdfile.conf.ext <<EOF
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u ${DOVECOT_USERS}
}

userdb {
  driver = static
  args = uid=${VMAIL_USERID} gid=${VMAIL_GROUPID} home=${VMAIL_DIR}/%d/%n
}
EOF

# SSL in Dovecot
sed -i "s|^#ssl = yes|ssl = yes|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "s|^ssl_cert = .*|ssl_cert = <${CERT_FILE}|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "s|^ssl_key = .*|ssl_key = <${KEY_FILE}|" /etc/dovecot/conf.d/10-ssl.conf

# Dovecot SASL socket for Postfix
sed -i '/^service auth {/,/}/ s/^#//g' /etc/dovecot/conf.d/10-master.conf
sed -i '/unix_listener auth-userdb {/,+2 s/^#//g' /etc/dovecot/conf.d/10-master.conf
sed -i '/unix_listener auth-userdb {/,+2 s/^}//g' /etc/dovecot/conf.d/10-master.conf
sed -i '/service auth {/a\
  # Postfix smtp-auth\
  unix_listener /var/spool/postfix/private/auth {\
    mode = 0660\
    user = postfix\
    group = postfix\
  }\
' /etc/dovecot/conf.d/10-master.conf

######################################
# 9) Create initial user in /etc/dovecot/users
######################################
mkdir -p /etc/dovecot
touch "${DOVECOT_USERS}"

echo "=== Creating a virtual mail user: ${VMAIL_USER} ==="
HASH=$(doveadm pw -s SHA512-CRYPT -p "${VMAIL_PASS}")
echo "${VMAIL_USER}:${HASH}" >> "${DOVECOT_USERS}"

chown root:dovecot "${DOVECOT_USERS}"
chmod 640 "${DOVECOT_USERS}"

######################################
# 10) Restart Postfix & Dovecot
######################################
echo "=== Restarting Postfix & Dovecot ==="
systemctl restart postfix
systemctl restart dovecot
systemctl enable postfix
systemctl enable dovecot

######################################
# 11) Prompt to Install Roundcube (SQLite)
######################################
read -rp "Would you like to also install Roundcube webmail (SQLite)? [y/N]: " INSTALL_ROUNDCUBE
if [[ "${INSTALL_ROUNDCUBE,,}" == "y" ]]; then
  echo "=== Installing Roundcube with SQLite support ==="
  apt-get install -y \
    apache2 \
    roundcube \
    roundcube-sqlite3 \
    php-mbstring php-xml php-json php-zip php-gd

  a2enmod php7.4 &>/dev/null || true
  a2enmod rewrite &>/dev/null || true

  # Symlink Roundcube into /var/www/html/roundcube
  if [ ! -d "/var/www/html/roundcube" ]; then
    ln -s /usr/share/roundcube /var/www/html/roundcube
  fi

  # Create SQLite DB file
  mkdir -p /var/lib/roundcube
  touch /var/lib/roundcube/roundcube.db
  chown -R www-data:www-data /var/lib/roundcube
  chmod 770 /var/lib/roundcube

  ROUNDCUBE_CONFIG="/etc/roundcube/config.inc.php"
  if [ ! -f "$ROUNDCUBE_CONFIG" ]; then
    cat > "$ROUNDCUBE_CONFIG" <<EOF
<?php
// Minimal config if not found
\$config['default_host'] = 'localhost';
\$config['smtp_server'] = 'localhost';
\$config['smtp_port'] = 25;
EOF
  fi

  # Configure db_dsnw for SQLite
  if grep -q "\$config\['db_dsnw'\]" "$ROUNDCUBE_CONFIG"; then
    sed -i "s|\(\$config\['db_dsnw'\]\).*=.*|\$config['db_dsnw'] = 'sqlite:////var/lib/roundcube/roundcube.db?mode=0640';|" "$ROUNDCUBE_CONFIG"
  else
    cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['db_dsnw'] = 'sqlite:////var/lib/roundcube/roundcube.db?mode=0640';
EOF
  fi

  # Prompt for IMAP SSL
  echo
  read -rp "Use IMAP SSL for Roundcube? [y/N]: " USE_SSL
  if [[ "${USE_SSL,,}" == "y" ]]; then
    DEFAULT_HOST="ssl://${MAIL_HOSTNAME}"
    DEFAULT_PORT="993"
  else
    DEFAULT_HOST="${MAIL_HOSTNAME}"
    DEFAULT_PORT="143"
  fi

  # Set default_host
  if grep -q "\$config\['default_host'\]" "$ROUNDCUBE_CONFIG"; then
    sed -i "s|\(\$config\['default_host'\]\).*=.*|\$config['default_host'] = '${DEFAULT_HOST}';|" "$ROUNDCUBE_CONFIG"
  else
    cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['default_host'] = '${DEFAULT_HOST}';
EOF
  fi

  # Set default_port
  if grep -q "\$config\['default_port'\]" "$ROUNDCUBE_CONFIG"; then
    sed -i "s|\(\$config\['default_port'\]\).*=.*|\$config['default_port'] = ${DEFAULT_PORT};|" "$ROUNDCUBE_CONFIG"
  else
    cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['default_port'] = ${DEFAULT_PORT};
EOF
  fi

  # Hide "Server" field
  if grep -q "\$config\['display_server_choice'\]" "$ROUNDCUBE_CONFIG"; then
    sed -i "s|\(\$config\['display_server_choice'\]\).*=.*|\$config['display_server_choice'] = false;|" "$ROUNDCUBE_CONFIG"
  else
    cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['display_server_choice'] = false;
EOF
  fi

  # If user selected self-signed cert, let's ignore validation in Roundcube
  if [ "${IGNORE_CERT_VALIDATION_IN_ROUNDCUBE}" = "true" ]; then
    # Remove existing imap_conn_options block if any
    if grep -q "\$config\['imap_conn_options'\]" "$ROUNDCUBE_CONFIG"; then
      sed -i "/\$config\['imap_conn_options'\]/,/);/d" "$ROUNDCUBE_CONFIG"
    fi
    cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['imap_conn_options'] = array(
  'ssl' => array(
    'verify_peer' => false,
    'verify_peer_name' => false,
  ),
);
EOF
    echo "Roundcube will ignore certificate validation due to self-signed certificate."
  fi

  systemctl enable apache2
  systemctl restart apache2

  echo "Roundcube installed. Access it at: http://<server-ip>/roundcube"
fi

######################################
# Final Output
######################################
echo "===================================================================="
echo "Installation and basic configuration complete."
echo "Domain:       ${MAIL_DOMAIN}"
echo "Hostname:     ${MAIL_HOSTNAME}"
echo "User:         ${VMAIL_USER}"
echo "Password:     ${VMAIL_PASS}"
echo
echo "If chosen, domain may be added to /etc/hosts => 127.0.0.1."
echo "Check logs at /var/log/mail.log or /var/log/syslog if something fails."
echo "Configure DNS (MX, SPF, DKIM, DMARC), real certs, spam filtering, etc."
echo "===================================================================="
