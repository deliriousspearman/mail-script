### Overview

This repository contains:

1. A script to set up a **Postfix + Dovecot** mail server on Ubuntu 22.04, using **virtual mailboxes** stored in a simple passwd-file.
2. An **interactive script** (`manage_mail_users.sh`) to list users, add new users, reset passwords, remove users, and test authentication.

This setup uses:

- **Dovecot** for IMAP/POP3 and SMTP authentication (SASL).
- **Postfix** for sending and receiving emails.
- A **passwd-file** (`/etc/dovecot/users`) for storing virtual user credentials (hashed via `doveadm pw`).
- A **Postfix vmailbox** file (`/etc/postfix/vmailbox`) to define virtual mailboxes.
- A dedicated `vmail` user/group for storing mail in `/var/mail/vhosts/`.

**Note**: This setup and scripts are **for demonstration or basic usage** and are **not** production-hardened. You’ll need to configure proper DNS (MX, SPF, DKIM, DMARC), obtain valid SSL certificates, enable spam filtering, and perform security hardening before using this in production.

---

### 1. Prerequisites

- **Ubuntu 22.04** (or a similar Debian-based system).
- Basic familiarity with the Linux command line.
- Root privileges (or `sudo`) on the server.
- Installed packages:
    - `postfix`
    - `dovecot-core`, `dovecot-imapd`, `dovecot-pop3d`
    - `openssl`
    - `bash`
    - `doveadm` command (part of the `dovecot` package)

---

### 2. Setup Script

`setup_mail_virtual.sh` (if included in your repository) is an **example** script that:

1. Installs and configures Postfix and Dovecot.
2. Creates the `vmail` user/group for mailbox ownership.
3. Generates a basic self-signed SSL certificate (for testing).
4. Configures Postfix for a specified domain (`/etc/postfix/vmailbox`) and virtual mailboxes.
5. Configures Dovecot to authenticate against `/etc/dovecot/users`.

After running `setup_mail_virtual.sh`, you’ll have a functional, but minimal, mail server.

**Usage**:


```bash
sudo chmod +x setup_mail_virtual.sh
sudo ./setup_mail_virtual.sh
```

You should then verify logs in `/var/log/mail.log` or `/var/log/syslog` if something fails, and adjust DNS (MX, SPF, etc.) if you’re hosting publicly.

---

### 3. Managing Users

The main script for adding and maintaining users is:

```
manage_mail_users.sh
```

#### Menu Options

Upon running this script, you will see a menu:

1. **List existing users**
    - Shows the users currently defined in `/etc/dovecot/users`.
2. **Add a new user**
    - Prompts for an email (`user@example.com`) and a password.
    - Hashes the password via `doveadm pw` and appends it to `/etc/dovecot/users`.
    - Adds the user to `/etc/postfix/vmailbox` if not already present.
3. **Reset an existing user's password**
    - Updates the password hash in `/etc/dovecot/users` if the user is found.
4. **Remove a user**
    - Removes them from both `/etc/dovecot/users` and `/etc/postfix/vmailbox`.
5. **Test authentication for a user**
    - Uses `doveadm auth test user@domain password` to see if authentication succeeds.
6. **Exit**
    - Exits the script.

**Usage**:

```bash
sudo chmod +x manage_mail_users.sh sudo ./manage_mail_users.sh
```

Follow the on-screen prompts.

---

### 4. Important Notes

7. **Permissions & Ownership**:
    
    - `/etc/dovecot/users` should be `root:dovecot` with permissions `640`.
    - This ensures the `dovecot` user (which handles authentication) can read the file without making it world-readable.
8. **AppArmor**:
    
    - On Ubuntu, AppArmor might block Dovecot from reading `/etc/dovecot/users` unless the file is in an allowed path.
    - If you see “Permission denied” errors in `/var/log/mail.log` or `/var/log/syslog`, you may need to create a local AppArmor override to grant read access.
9. **DNS Configuration**:
    
    - You must have a valid **MX record** pointing to your mail server.
    - Properly set up **SPF**, **DKIM**, and **DMARC** to avoid spam/junk issues.
10. **SSL Certificates**:
    
    - By default, `setup_mail_virtual.sh` creates a self-signed certificate at `/etc/ssl/certs/<hostname>.pem`, which will cause warnings in mail clients.
    - Replace these with certificates from a trusted CA (e.g., Let’s Encrypt) for a production environment.
11. **Security & Performance**:
    
    - Consider enabling **fail2ban**, **firewall** rules, spam/virus filtering, and other best practices.
    - For higher-volume or multi-domain hosting, you might want a more advanced setup (SQL/LDAP backends, load balancing, etc.).

---

### 5. Troubleshooting

- **Check Logs**:
    - `/var/log/mail.log` or `/var/log/syslog` often shows detailed errors from Postfix and Dovecot.
- **Authentication Fails**:
    - Verify `/etc/dovecot/users` has correct ownership (`root:dovecot`) and permissions (`640`).
    - Run `manage_mail_users.sh` → “Test authentication for a user” to check credentials.
- **Cannot Receive External Emails**:
    - Ensure DNS has a valid MX record pointing to your server.
    - Ports 25 (SMTP), 587 (Submission), and possibly 993 (IMAPS) are open in the firewall.
- **Cannot Send**:
    - Check your ISP or host if outbound SMTP (port 25) is blocked. Some VPS providers block SMTP by default.
    - Review Postfix logs for “relay access denied” or other errors.
