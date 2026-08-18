#!/usr/bin/env bash
# Erzeugt alle Geheimnisse fuer den Omni-Stack nach secrets/:
#   - selbstsignierte Root-CA und ein Serverzertifikat fuer Omni und Dex
#   - GPG-Schluessel, mit dem Omni seine etcd-Daten verschluesselt
#   - bcrypt-Hash des Admin-Passworts fuer Dex
#
# Idempotent: vorhandene Dateien bleiben, sofern nicht --force gesetzt ist.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_vars OMNI_ENDPOINT AUTH_ENDPOINT OMNI_HOST_IP OMNI_USER_EMAIL

need_cmd openssl
need_cmd gpg
need_cmd docker "wird nur fuer den bcrypt-Hash gebraucht"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then FORCE=1; fi

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

CA_KEY="${SECRETS_DIR}/ca-key.pem"
CA_CRT="${SECRETS_DIR}/ca.pem"
SRV_KEY="${SECRETS_DIR}/server-key.pem"
SRV_CRT="${SECRETS_DIR}/server.pem"
SRV_CHAIN="${SECRETS_DIR}/server-chain.pem"
GPG_KEY="${SECRETS_DIR}/omni.asc"
DEX_HASH="${SECRETS_DIR}/dex-password.hash"

# --- 1. Root-CA ------------------------------------------------------------
if [[ -s "${CA_CRT}" && ${FORCE} -eq 0 ]]; then
  ok "Root-CA existiert bereits (--force zum Neuerzeugen)"
else
  log "Erzeuge Root-CA"
  openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
    -keyout "${CA_KEY}" -out "${CA_CRT}" \
    -subj "/C=DE/O=Internal Infrastructure/OU=Security/CN=Omni Internal Root CA" \
    2>/dev/null
  ok "${CA_CRT}"
fi

# --- 2. Serverzertifikat ---------------------------------------------------
# Ein Zertifikat deckt beide Endpunkte ab. Die IPs muessen mit hinein, weil
# Clients teils ueber den Hostnamen und teils ueber die IP verbinden.
if [[ -s "${SRV_CHAIN}" && ${FORCE} -eq 0 ]]; then
  ok "Serverzertifikat existiert bereits"
else
  log "Erzeuge Serverzertifikat fuer ${OMNI_ENDPOINT}, ${AUTH_ENDPOINT}, ${OMNI_HOST_IP}"

  SAN_CONF="${CACHE_DIR}/san.cnf"
  cat > "${SAN_CONF}" <<EOF
[req]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no

[dn]
CN = ${OMNI_ENDPOINT}

[v3_req]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt

[alt]
DNS.1 = ${OMNI_ENDPOINT}
DNS.2 = ${AUTH_ENDPOINT}
IP.1  = 127.0.0.1
IP.2  = ${OMNI_HOST_IP}
EOF

  openssl req -new -newkey rsa:4096 -nodes \
    -keyout "${SRV_KEY}" -out "${CACHE_DIR}/server.csr" \
    -config "${SAN_CONF}" 2>/dev/null

  openssl x509 -req -in "${CACHE_DIR}/server.csr" \
    -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -out "${SRV_CRT}" -days 825 -sha256 \
    -extfile "${SAN_CONF}" -extensions v3_req 2>/dev/null

  # Omni und Dex bekommen die Kette, damit Clients bis zur CA verifizieren koennen.
  cat "${SRV_CRT}" "${CA_CRT}" > "${SRV_CHAIN}"
  chmod 644 "${SRV_CRT}" "${SRV_CHAIN}"
  chmod 600 "${SRV_KEY}"
  rm -f "${CACHE_DIR}/server.csr"
  ok "${SRV_CHAIN}"

  dim "SANs im Zertifikat:"
  openssl x509 -in "${SRV_CRT}" -noout -text \
    | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/^/       /'
fi

# --- 3. GPG-Schluessel fuer die etcd-Verschluesselung ----------------------
# Eigener Keyring unter secrets/, damit der persoenliche Schluesselbund
# unangetastet bleibt.
if [[ -s "${GPG_KEY}" && ${FORCE} -eq 0 ]]; then
  ok "GPG-Schluessel existiert bereits"
else
  log "Erzeuge GPG-Schluessel fuer die etcd-Verschluesselung"
  export GNUPGHOME="${SECRETS_DIR}/gnupg"
  rm -rf "${GNUPGHOME}"
  mkdir -p "${GNUPGHOME}"
  chmod 700 "${GNUPGHOME}"

  # Ohne Passphrase: Omni liest die Datei beim Start und kann nicht nachfragen.
  gpg --batch --passphrase '' --quick-generate-key \
    "Omni (etcd data encryption) omni@internal.local" rsa4096 cert never 2>/dev/null

  FPR="$(gpg --with-colons --list-keys omni@internal.local | awk -F: '$1=="fpr"{print $10; exit}')"
  [[ -n "${FPR}" ]] || die "GPG-Fingerprint konnte nicht ermittelt werden"

  gpg --batch --passphrase '' --quick-add-key "${FPR}" rsa4096 encr never 2>/dev/null
  gpg --export-secret-key --armor omni@internal.local > "${GPG_KEY}"
  chmod 600 "${GPG_KEY}"
  unset GNUPGHOME
  ok "${GPG_KEY}"
fi

# --- 3b. OAuth2-Client-Secret fuer Dex -------------------------------------
# Die Dokumentation nutzt hier ein festes "omni-dex-secret". Ein zufaelliges
# Secret kostet nichts und vermeidet, dass ein bekannter Wert im Einsatz ist.
DEX_SECRET_FILE="${SECRETS_DIR}/dex-client-secret"
if [[ -s "${DEX_SECRET_FILE}" && ${FORCE} -eq 0 ]]; then
  ok "Dex-Client-Secret existiert bereits"
else
  openssl rand -hex 32 | tr -d '\n' > "${DEX_SECRET_FILE}"
  chmod 600 "${DEX_SECRET_FILE}"
  ok "${DEX_SECRET_FILE}"
fi

# --- 4. Dex-Passworthash ---------------------------------------------------
if [[ -s "${DEX_HASH}" && ${FORCE} -eq 0 ]]; then
  ok "Dex-Passworthash existiert bereits"
else
  log "Admin-Passwort fuer den Omni-Login (${OMNI_USER_EMAIL})"
  read -rsp "     Passwort: " PW1; echo
  read -rsp "     Wiederholen: " PW2; echo
  [[ "${PW1}" == "${PW2}" ]] || die "Passwoerter stimmen nicht ueberein"
  (( ${#PW1} >= 8 )) || die "Passwort muss mindestens 8 Zeichen haben"

  # bcrypt via httpd-Image; lokal ist htpasswd auf macOS nicht bcrypt-faehig.
  docker run --rm httpd:2.4-alpine htpasswd -Bbn admin "${PW1}" 2>/dev/null \
    | cut -d: -f2 | tr -d '\n' > "${DEX_HASH}"
  unset PW1 PW2
  [[ -s "${DEX_HASH}" ]] || die "Passworthash konnte nicht erzeugt werden"
  chmod 600 "${DEX_HASH}"
  ok "${DEX_HASH}"
fi

echo
ok "Geheimnisse liegen in secrets/ (gitignored)."
warn "secrets/ enthaelt private Schluessel — nicht committen, nicht teilen."
dim "Naechster Schritt: scripts/20-deploy-omni.sh"
