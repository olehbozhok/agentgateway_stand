#!/bin/sh
# Creates, once, what the Janssen configurator expects on first start: a CA, a TLS certificate
# for $JANS_FQDN signed by it, and configuration.json with both. Runs in the all-in-one image
# (it has openssl and base64) and writes to the jans-init volume mounted at /out.
# Adapted from prepare_certs and prepare_jans_configuration in automation/start_janssen_aio_demo.sh.
set -eu
cd /out
fqdn="${JANS_FQDN:?}"

if [ -f configuration.json ] && grep -q "\"hostname\": \"$fqdn\"" configuration.json; then
  echo "[init] configuration for $fqdn exists"
  exit 0
fi

rm -f ca.key ca.crt web_https.key web_https.csr web_https.crt configuration.json
openssl genrsa -out ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt \
  -subj '/CN=Stand Root CA/O=agentgateway-stand'
openssl genrsa -out web_https.key 2048 2>/dev/null
openssl req -new -key web_https.key -out web_https.csr -subj "/CN=$fqdn/O=agentgateway-stand"
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nsubjectAltName=DNS:%s\n' "$fqdn" > v3.ext
openssl x509 -req -in web_https.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out web_https.crt -days 3650 -sha256 -extfile v3.ext 2>/dev/null
rm -f v3.ext ca.srl

b64() { base64 -w0 "$1"; }
cat > configuration.json <<EOF
{
  "_secret": {
    "admin_password": "Test1234#",
    "sql_password": "Test1234#",
    "ssl_ca_cert": "$(b64 ca.crt)",
    "ssl_ca_key": "$(b64 ca.key)",
    "ssl_cert": "$(b64 web_https.crt)",
    "ssl_key": "$(b64 web_https.key)",
    "ssl_csr": "$(b64 web_https.csr)"
  },
  "_configmap": {
    "city": "Austin",
    "country_code": "US",
    "admin_email": "support@$fqdn",
    "hostname": "$fqdn",
    "state": "TX",
    "orgName": "agentgateway-stand",
    "optional_scopes": "[\"sql\"]"
  }
}
EOF

# The all-in-one image runs as uid 1000; the CA certificate is also read by other services.
chown -R 1000:1000 /out
chmod 644 ca.crt web_https.crt
chmod 640 ca.key web_https.key configuration.json
echo "[init] created CA, certificate and configuration for $fqdn"
