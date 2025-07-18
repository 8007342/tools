#!/bin/bash

# Run this file in a cron job like so:
#
# bash <(curl -sSL https://raw.githubusercontent.com/8007342/tools/main/update-external-address.sh) --hosted_zone_id=<my_hosted_zone> <my_domain>
#
# Don't forget your session vars: 
#    AWS_ACCESS_KEY_ID=SOME_SECRET
#    AWS_SECRET_ACCESS_KEY=MORE_SECRETS

# For debugging purposes
DRY_RUN=false

# Parse arguments
DOMAIN=""
HOSTED_ZONE_ID=""
# Use "valhalla" as the default dmz zone for everything
DMZ_ZONE=valhalla
for arg in "$@"; do
  case ${arg} in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --hosted_zone_id=*)
      HOSTED_ZONE_ID="${arg#--hosted_zone_id=}"
      shift
      ;;
    *)
      # If DOMAIN is not set and argument doesn't start with --
      if [[ -z "$DOMAIN" && "${arg}" != --* ]]; then
        DOMAIN="${arg}"
        shift
      fi
      ;;
  esac
done

if [[ -z "${DOMAIN}" || -z "${HOSTED_ZONE_ID}" ]]; then
  echo "Usage: $0 [--dry-run] <domain> --hosted_zone_id=<MY_HOSTED_ZONE_ID>"
  echo "Example: $0 --dry-run example.com --hosted_zone_id=123456789ABCDEF0"
  exit
fi

# Fetch IPs
IP4=$(curl -s https://api.ipify.org)
IP6=$(curl -s https://api64.ipify.org)

# Pick the one that's valid (IPv6 preferred if present)
if [[ -n "${IP6}" && "${IP6}" =~ : ]]; then
  IP="${IP6}"
  TYPE="AAAA"
  SPF_TYPE="ip6"
else
  IP="${IP4}"
  TYPE="A"
  SPF_TYPE="ip4"
fi


DKIM_DIR="/etc/dkimkeys/"
DKIM_DOMAIN="${DOMAIN}"
DKIM_SELECTOR="default"
DKIM_PRIVKEY="${DKIM_DIR}/${DKIM_SELECTOR}.private"
DKIM_TXT="${DKIM_DIR}/${DKIM_SELECTOR}.txt"

# Generate keys if they don't exist
if [ ! -f "${DKIM_PRIVKEY}" ] || [ ! -f "${DKIM_TXT}" ]; then
	echo "Generating DKIM keypair..."
	opendkim-genkey -s "${DKIM_SELECTOR}" -d "${DKIM_DOMAIN}" -D "${DKIM_DIR}"
	echo "DKIM keys created at ${DKIM_DIR}/"
	
	chown opendkim:opendkim "${DKIM_PRIVKEY}"
	chmod 0700 "${DKIM_PRIVKEY}"
fi

DKIM_TXT_VALUE=$(grep -oP '"[^"]+"' ${DKIM_TXT} | tr -d '"' | tr -d '\n' | fold -w250 | sed 's/^/\\"/;s/$/\\" /' | tr -d '\n')

# Build Route 53 change batch
cat > "${DKIM_DIR}/change-batch.json" <<EOF
{
  "Comment": "Update ${TYPE} and SPF TXT record dynamically",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DMZ_ZONE}.${DOMAIN}",
        "Type": "${TYPE}",
        "TTL": 86400,
        "ResourceRecords": [
          {
            "Value": "${IP}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "mail.${DOMAIN}",
        "Type": "${TYPE}",
        "TTL": 86400,
        "ResourceRecords": [
          {
            "Value": "${IP}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "${TYPE}",
        "TTL": 86400,
        "ResourceRecords": [
          {
            "Value": "${IP}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DMZ_ZONE}.${DOMAIN}",
        "Type": "TXT",
        "TTL": 86400,
        "ResourceRecords": [
          {
            "Value": "\"v=spf1 ${SPF_TYPE}:${IP} -all\""
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "mail.${DOMAIN}",
        "Type": "TXT",
        "TTL": 86400,
        "ResourceRecords": [
          {
            "Value": "\"v=spf1 ${SPF_TYPE}:${IP} -all\""
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "TXT",
        "TTL": 86400,
        "ResourceRecords": [
          {
            "Value": "\"v=spf1 ${SPF_TYPE}:${IP} -all\""
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "_acme-challenge.${DOMAIN}",
        "Type": "TXT",
        "TTL": 86400,
        "ResourceRecords": [
          {
            "Value": "\"0UkLR2h7QAKeU1xGwuToYVvSV3jEohBeYHgDH8RYTw8\""
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "default._domainkey.${DOMAIN}",
        "Type": "TXT",
        "TTL": 86400,
        "ResourceRecords": [
          {
			       "Value": "${DKIM_TXT_VALUE}"
          }
        ]
      }
    }
  ]
}
EOF


if [ "${DRY_RUN}" = true ]; then
  echo "[DRY RUN] Here's the generated change-batch.json:"
  cat change-batch.json
else
  # Send it off to route53 way
  aws route53 change-resource-record-sets \
    --hosted-zone-id ${HOSTED_ZONE_ID} \
    --change-batch file://${DKIM_DIR}/change-batch.json
fi
