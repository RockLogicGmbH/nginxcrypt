#!/bin/bash

#
# HANDLE PSUEDO BOOLEANS
#

# Set NXCT_SERVICE_DRYRUN to "no" if it is explicitly "false", "no", empty, or not set.
# Set it to "yes" otherwise
NXCT_SERVICE_DRYRUN="${NXCT_SERVICE_DRYRUN,,}"
if [ -z "$NXCT_SERVICE_DRYRUN" ] || [ "$NXCT_SERVICE_DRYRUN" = "false" ] || [ "$NXCT_SERVICE_DRYRUN" = "no" ]; then
  NXCT_SERVICE_DRYRUN="no"
else
  NXCT_SERVICE_DRYRUN="yes"
fi

# Set NXCT_SERVICE_DELTEOUTDATEDCERTS to "no" if it is explicitly "false", "no", empty, or not set.
# Set it to "yes" otherwise
NXCT_SERVICE_DELTEOUTDATEDCERTS="${NXCT_SERVICE_DELTEOUTDATEDCERTS,,}"
if [ -z "$NXCT_SERVICE_DELTEOUTDATEDCERTS" ] || [ "$NXCT_SERVICE_DELTEOUTDATEDCERTS" = "false" ] || [ "$NXCT_SERVICE_DELTEOUTDATEDCERTS" = "no" ]; then
  NXCT_SERVICE_DELTEOUTDATEDCERTS="no"
else
  NXCT_SERVICE_DELTEOUTDATEDCERTS="yes"
fi

# Set NXCT_SERVICE_ALLOWUNKNOWNDOMAINS to "no" if it is explicitly "false", "no", empty, or not set.
# Set it to "yes" otherwise
NXCT_SERVICE_ALLOWUNKNOWNDOMAINS="${NXCT_SERVICE_ALLOWUNKNOWNDOMAINS,,}"
if [ -z "$NXCT_SERVICE_ALLOWUNKNOWNDOMAINS" ] || [ "$NXCT_SERVICE_ALLOWUNKNOWNDOMAINS" = "false" ] || [ "$NXCT_SERVICE_ALLOWUNKNOWNDOMAINS" = "no" ]; then
  NXCT_SERVICE_ALLOWUNKNOWNDOMAINS="no"
else
  NXCT_SERVICE_ALLOWUNKNOWNDOMAINS="yes"
fi

#
# FUNCTIONS
#

# output default message
say() {
    echo "$@"
}

# exit script with error message and error code
die() {
    echo "$@" >&2
    exit 3
}

# trim whitespaces
# example: myvar=$(trim "$myvar")
trim() {
    local var="$*"
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"   
    echo -n "$var"
}

# Get public IP address (from multiple different services to also validate it)
get_public_ip(){
  if ! public_ip_svc1=$(dig +short myip.opendns.com @resolver1.opendns.com); then
    return 1
  fi
  if ! public_ip_svc2=$(curl -s https://api.ipify.org); then
    return 2
  fi
  if [ "$public_ip_svc1" != "$public_ip_svc2" ]; then
    return 3
  fi
  echo "$public_ip_svc1"
  return 0
}

# Get the domain's IP address(es) from DNS
# $1 = The domain to get IP address(es) from
get_domain_ips_from_dns(){
  local DOMAIN="$1"
  local domain_ips=$(dig +short "$DOMAIN" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
  if [ -z "$domain_ips" ]; then
    return 1
  fi
  echo "$domain_ips"
  return 0
}

# Check if public IP is in domain IPs
# $1 = The public IP retrieved by "get_public_ip"
# $2 = The domain IPs retrieved by "get_domain_ips_from_dns"
is_public_ip_in_domain_ips(){
  local public_ip="$1"
  local domain_ips="$2"
  local domain_ip=""
  for domain_ip in $domain_ips; do
    if [ "$public_ip" = "$domain_ip" ]; then
      return 0
    fi
  done
  return 1
}

# Check if given domain is ponted to the local machine
# $1 = The domain to check
is_domain_pointed_to_local_machine(){
  local DOMAIN="$1"
  if [ -z "$DOMAIN" ]; then
    #echo "No domain given"
    return 1
  fi
  # Get public machine IP
  if ! public_ip=$(get_public_ip); then
    #echo "Unable to get public IP address of local machine."
    return 2
  fi
  # Get domain IPs
  if ! domain_ips=$(get_domain_ips_from_dns "$DOMAIN"); then
    #echo "Unable to resolve IP addresses for $DOMAIN."
    return 3
  fi
  # Check if the public machine IP matches any of the domain IPs
  if ! is_public_ip_in_domain_ips "$public_ip" "$domain_ips"; then
    #echo "Domain $DOMAIN is NOT pointed to the local machine."
    return 4
  fi
  #echo "Domain $DOMAIN is pointed to the local machine."
  return 0
}

# Get curve name from curve key
# $1 = Curve key: ec-256, ec-384, ec-521
get_ec_curve_name() {
    local ec_key="$1"

    # Extract the numeric part of the curve size (256, 384, 521)
    local curve_size=${ec_key#ec-}

    # Map curve size to the appropriate curve name
    case $curve_size in
        256)
            echo "secp256r1"
            ;;
        384)
            echo "secp384r1"
            ;;
        521)
            echo "secp521r1"
            ;;
        *)
            #echo "Unsupported EC curve size: $curve_size" >&2
            return 1
            ;;
    esac
}

# Get certificate key size from existing key file
# $1 = Path to fullchain.pem file
get_key_size(){
  local fullchainpem="$1"

  algo=$(openssl x509 -in "$fullchainpem" -noout -text | grep "Public Key Algorithm" | awk '{print $4}')



  if ! key_size=$(openssl x509 -in $fullchainpem -noout -text | grep 'Public-Key' | awk -F'[()]' '{print $2}' | awk '{print $1}'); then
    return 1
  fi
  echo "$key_size"
  return 0
}

# Get certificate key algorithm from existing key file
# $1 = Path to fullchain.pem file
# Returns key algo like 'RSA' or 'id-ecPublicKey' and so on...
get_key_algo(){
  local fullchainpem="$1"
  if ! key_algo=$(openssl x509 -in "$fullchainpem" -noout -text | grep "Public Key Algorithm" | awk '{print $4}'); then
    return 1
  fi
  echo "$key_algo"
  return 0
}

# Get DH params key size from existing key file
# $1 = Path to dhparam.pem file
get_dh_key_size(){
  local dhparampem="$1"
  if ! dh_key_size=$(openssl dhparam -in $dhparampem -noout -text | grep 'DH Parameters'  | awk -F'[()]' '{print $2}' | awk '{print $1}'); then
    return 1
  fi
  echo "$dh_key_size"
  return 0
}

#
# MAIN FLOW
#

# Define default host and frontend/backend proxy (used in case none was given by environment vars)
DEFAULT_NXCT_SERVICE_HOST="localhost"
DEFAULT_NXCT_SERVICE_FRONTEND_TARGET="frontend:80"
DEFAULT_NXCT_SERVICE_BACKEND_TARGET="backend:80"

# If no NXCT_SERVICE_HOST was specified and DEFAULT_NXCT_SERVICE_HOST is set to "localhost" or "127.0.0.1":
# "yes" = Accept connection from both, 127.0.0.1 and localhost
# "no"  = Accept connection only from the given host
DEFAULT_NXCT_SERVICE_ALLOW_LOCAL_HOST_AND_ADDR="yes"

# Define a default key length for the certificate, and use the parameter if set
# Set it to 2048 at least!
keyLength=4096
if [ -n "$NXCT_SERVICE_KEYLENGTH" ]; then
  if [[ $NXCT_SERVICE_KEYLENGTH == ec-* ]]; then
      if ! curveName=$(get_ec_curve_name "$NXCT_SERVICE_KEYLENGTH"); then
        die "ERROR: NXCT_SERVICE_KEYLENGTH is an unsupported EC curve size: $NXCT_SERVICE_KEYLENGTH"
      fi
  else
    if ! [[ "$NXCT_SERVICE_KEYLENGTH" =~ ^[0-9]+$ ]]; then
      die "ERROR: NXCT_SERVICE_KEYLENGTH is not a valid numeric value: $NXCT_SERVICE_KEYLENGTH"
    fi
    if [ "$NXCT_SERVICE_KEYLENGTH" -lt 2048 ]; then
      die "ERROR: NXCT_SERVICE_KEYLENGTH $NXCT_SERVICE_KEYLENGTH is lower than 2048!"
    fi
  fi
  keyLength=$NXCT_SERVICE_KEYLENGTH
fi

# Should we execute everything on LE's staging platform?
test=""
if [ "$NXCT_SERVICE_DRYRUN" = "yes" ]; then
  test="--test"
fi

# Define a default DH params length, and use the parameter if set
# Set it to 2048 at least!
dhParamLength=2048
if [ -n "$NXCT_SERVICE_DHPARAM" ]; then
  if ! [[ "$NXCT_SERVICE_DHPARAM" =~ ^[0-9]+$ ]]; then
    die "ERROR: NXCT_SERVICE_DHPARAM is not a valid numeric value: $NXCT_SERVICE_DHPARAM"
  fi
  if [ "$NXCT_SERVICE_DHPARAM" -lt 2048 ]; then
    die "ERROR: NXCT_SERVICE_DHPARAM $NXCT_SERVICE_DHPARAM is lower than 2048!"
  fi
  dhParamLength=$NXCT_SERVICE_DHPARAM
fi

# Read defined services
services=$(env | grep NXCT_SERVICE_HOST_ | cut -d "=" -f1 | sed 's/^NXCT_SERVICE_HOST_//')

# Check if at least one NXCT_SERVICE_HOST_$service exists
hosts_exist="no"
for service in $services
do
  host="NXCT_SERVICE_HOST_$service"
  if [ ! -z "${!host}" ]; then
    hosts_exist="yes"
    break
  fi
done

# Generate defaults if no NXCT_SERVICE_HOST_$service exists
if [ "$hosts_exist" = "no" ]; then
  export NXCT_SERVICE_HOST_1="$DEFAULT_NXCT_SERVICE_HOST"
  export NXCT_SERVICE_FRONTEND_TARGET_1="$DEFAULT_NXCT_SERVICE_FRONTEND_TARGET"
  export NXCT_SERVICE_BACKEND_TARGET_1="$DEFAULT_NXCT_SERVICE_BACKEND_TARGET"
  if [ "$DEFAULT_NXCT_SERVICE_ALLOW_LOCAL_HOST_AND_ADDR" = "yes" ]; then
    if [ "$DEFAULT_NXCT_SERVICE_HOST" == "localhost" ]; then
      export NXCT_SERVICE_HOST_2="127.0.0.1"
      export NXCT_SERVICE_FRONTEND_TARGET_2="$DEFAULT_NXCT_SERVICE_FRONTEND_TARGET"
      export NXCT_SERVICE_BACKEND_TARGET_2="$DEFAULT_NXCT_SERVICE_BACKEND_TARGET"
    elif [ "$DEFAULT_NXCT_SERVICE_HOST" == "127.0.0.1" ]; then
      export NXCT_SERVICE_HOST_2="localhost"
      export NXCT_SERVICE_FRONTEND_TARGET_2="$DEFAULT_NXCT_SERVICE_FRONTEND_TARGET"
      export NXCT_SERVICE_BACKEND_TARGET_2="$DEFAULT_NXCT_SERVICE_BACKEND_TARGET"
    fi
  fi
  services=$(env | grep NXCT_SERVICE_HOST_ | cut -d "=" -f1 | sed 's/^NXCT_SERVICE_HOST_//')
fi

# Delete existing certs of undefined hosts
if [ "$NXCT_SERVICE_DELTEOUTDATEDCERTS" = "yes" ]; then
  for dir in /certs/*/; do
    # Get the basename of the directory
    dir_basename=$(basename "$dir")
    exists="no"
    for service in $services
    do
      host="NXCT_SERVICE_HOST_$service"
      name=${!host}
      if [ "$dir_basename" == "$name" ]; then
        exists="yes"
        break
      fi
    done
    if [ $exists = "no" ]; then
      if [ "$NXCT_SERVICE_DRYRUN" = "yes" ]; then
        echo "[DRY-RUN] Deleting certs of undefined host '$dir_basename'"
      else
        echo "Deleting certs of undefined host '$dir_basename' ($dir)"
        rm -rf "$dir"
      fi
    fi
  done
fi

# Generating self-signed certificates for each host, mandatory for Nginx and LE to execute properly
for service in $services
do
  host="NXCT_SERVICE_HOST_$service"
  subj="NXCT_SERVICE_SUBJ_$service"

  # Make sure certificates are re-generated if minimum key sizes does not fit anymore (for example due to NGINX upgrades)
  if [ -s "/certs/${!host}/fullchain.pem" ]; then
    if ! key_size=$(get_key_size "/certs/${!host}/fullchain.pem"); then
      die "ERROR: could not get key size from /certs/${!host}/fullchain.pem"
    fi
    if ! key_algo=$(get_key_algo "/certs/${!host}/fullchain.pem"); then
      die "ERROR: could not get key algorithm from /certs/${!host}/fullchain.pem"
    fi
    if ( [ "$key_algo" == "rsaEncryption" ] || [ "$key_algo" == "RSA" ] ) && [ "$key_size" -lt 2048 ]; then
      echo "WARNING: RSA key_size $key_size is lower than 2048, removing \"/certs/${!host}\" directory to re-generate certificates!"
      rm -rf "/certs/${!host}"
    elif ( [ "$key_algo" == "ecEncryption" ] || [ "$key_algo" == "id-ecPublicKey" ] || [[ "$key_algo" == secp* ]] || [[ "$alkey_algogo" == prime* ]]) && [ "$key_size" -lt 256 ]; then
      echo "WARNING: EC key_size $key_size is lower than 256, removing \"/certs/${!host}\" directory to re-generate certificates!"
      rm -rf "/certs/${!host}"
    fi
  fi

  # if [[ ! -d "/certs/${!host}"  || ! -s "/certs/${!host}/cert.pem" ]]; then # only generates a new self-signed if cert.pem not empty
  if [[ ! -d "/certs/${!host}"  || ! -f "/certs/${!host}/cert.pem" ]]; then # only generates a new self-signed if cert.pem does not exist
    echo ""
    echo "Generating a self-signed certificate for ${!host}..."
    certSubj="/C=EU/ST=My State/L=My City/O=My Organization/OU=My Domain/CN=${!host}"
    if [ -n "${!subj}" ]; then
      certSubj=${!subj}
    fi
    mkdir -vp /certs/${!host}
    if [[ $keyLength == ec-* ]]; then
      if ! curveName=$(get_ec_curve_name "$keyLength"); then
        die "ERROR: Unsupported EC curve size: $keyLength"
      fi
      /usr/bin/openssl ecparam -name $curveName -genkey -noout -out /certs/${!host}/key.pem
    else
      /usr/bin/openssl genrsa -out /certs/${!host}/key.pem $keyLength
    fi
    /usr/bin/openssl req -new -key /certs/${!host}/key.pem \
            -out /certs/${!host}/cert.csr \
            -subj "$certSubj"
    /usr/bin/openssl x509 -req -days 365 -in /certs/${!host}/cert.csr \
            -signkey /certs/${!host}/key.pem \
            -out /certs/${!host}/cert.pem
    rm /certs/${!host}/cert.csr
    cp /certs/${!host}/cert.pem /certs/${!host}/fullchain.pem
    echo "Self-signed certificate for ${!host} successfully created."
    echo ""
  fi
done

# Generate the DH params file if it does not exist or make sure it is re-generated
# if the minimum key size does not fit anymore (for example due to NGINX upgrades)
if [ -s "/certs/dhparam.pem" ]; then
  if ! dh_key_size=$(get_dh_key_size "/certs/dhparam.pem"); then
    die "ERROR: could not get DH key size"
  fi
  if [ "$dh_key_size" -lt 2048 ]; then
    echo "WARNING: dh_key_size $dh_key_size is lower than 2048, removing \"/certs/dhparam.pem\" to re-generate it!"
    rm -rf "/certs/dhparam.pem"
  fi
fi
if [ ! -s "/certs/dhparam.pem" ]; then
  echo ""
  echo "Generating DH Parameters (length: $dhParamLength)..."
  echo "It can be quite long (several minutes), and no log will be displayed."
  echo "Do not worry, and wait for the generation to be done."
  /usr/bin/openssl dhparam -out /certs/dhparam.pem $dhParamLength
  echo "DH Parameters generated."
  echo ""
fi

# Create Nginx configurations
find /conf -type f -regex '.*/\d\+\.conf' -delete # removes 0.conf, 1.conf, 21.conf, ... (not somname.conf)
cp /tmp/service.conf.default.template /conf/0.conf
for service in $services
do
  host="NXCT_SERVICE_HOST_$service"
  proxy="NXCT_SERVICE_PROXY_$service"
  feproxy="NXCT_SERVICE_FRONTEND_TARGET_$service"
  beproxy="NXCT_SERVICE_BACKEND_TARGET_$service"
  if [ -z "${!feproxy}" ] && ! [ -z "${!beproxy}" ]; then
      feproxy="DEFAULT_NXCT_SERVICE_FRONTEND_TARGET"
      echo "set empty feproxy to DEFAULT_NXCT_SERVICE_FRONTEND_TARGET"
  fi
  if [ -z "${!beproxy}" ] && ! [ -z "${!feproxy}" ]; then
      beproxy="DEFAULT_NXCT_SERVICE_BACKEND_TARGET"
      echo "set empty beproxy to DEFAULT_NXCT_SERVICE_BACKEND_TARGET"
  fi
  if [ -z "${!proxy}" ] && [ -z "${!feproxy}" ] && [ -z "${!beproxy}" ]; then
      proxy="DEFAULT_NXCT_SERVICE_FRONTEND_TARGET"
      echo "set empty proxy to DEFAULT_NXCT_SERVICE_FRONTEND_TARGET"
  fi
  echo "Generating Nginx configuration for \"${!host}\"."
  FILE_NAME=$(echo $service | tr '[:upper:]' '[:lower:]').conf
  if ! [ -z "${!proxy}" ]; then
    TEMPLATE="service.conf.min.template"
  else
    TEMPLATE="service.conf.api.template"
  fi
  DOMAIN=${!host} PROXY=${!proxy} FRONTEND_PROXY=${!feproxy} BACKEND_PROXY=${!beproxy} envsubst '$PROXY,$DOMAIN,$FRONTEND_PROXY,$BACKEND_PROXY' < /tmp/${TEMPLATE} > "/conf/${FILE_NAME}"
done

# Starting Nginx in daemon mode (and make sure hosts are valid)
echo "Starting Nginx in daemon mode"
if ! /usr/sbin/nginx; then
  exit 3
fi

# Commented since this is now done in Dockerfile
# /root/.acme.sh/acme.sh --set-default-ca  --server letsencrypt

# ZeroSSL not supported for the moment
# if [ -n "$NXCT_SERVICE_EMAIL" ]; then
#   /root/.acme.sh/acme.sh  --register-account  -m $NXCT_SERVICE_EMAIL --server zerossl
# fi

# Request and install a Let's Encrypt certificate for each host
for service in $services
do
  host="NXCT_SERVICE_HOST_$service"
  if ! is_domain_pointed_to_local_machine "${!host}" && [ "$NXCT_SERVICE_ALLOWUNKNOWNDOMAINS" != "yes" ]; then
    echo "Ignoring Let's Encrypt certificate request for host ${!host} (domain NOT pointed to the local machine)"
    continue
  fi
  certSubject=`/usr/bin/openssl x509 -subject -noout -in /certs/${!host}/cert.pem | /usr/bin/cut -c9-999`
  certIssuer=`/usr/bin/openssl x509 -issuer -noout -in /certs/${!host}/cert.pem | /usr/bin/cut -c8-999`
  # Checking whether the existent certificate is self-signed or not
  # If self-signed: remove the le-ok file
  if [[ -e /certs/${!host}/le-ok && "$certSubject" = "$certIssuer" ]]; then
    rm /certs/${!host}/le-ok
  fi
  # Replace the existing self-signed certificate with a LE one
  if [ ! -e /certs/${!host}/le-ok ]; then
    ecc=""
    keyLengthTest=`echo "$keyLength" | /usr/bin/cut -c1-2`
    if [ "$keyLengthTest" = "ec" ]; then
      ecc="--ecc"
    fi
    echo ""
    echo "Requesting a certificate from Let's Encrypt certificate for ${!host}..."
    /root/.acme.sh/acme.sh $test --log --issue -w /var/www/html/ -d ${!host} -k $keyLength
    /root/.acme.sh/acme.sh $test --log --installcert $ecc -d ${!host} \
                           --key-file /certs/${!host}/key.pem \
                           --fullchain-file /certs/${!host}/fullchain.pem \
			   --cert-file /certs/${!host}/cert.pem \
                           --reloadcmd '/usr/sbin/nginx -s stop && /bin/sleep 5s && /usr/sbin/nginx'
    touch /certs/${!host}/le-ok
    echo "Let's Encrypt certificate for ${!host} installed."
    echo ""
  fi
done

# Chmod certs
# 777 is set for test purposes only, please set it to 600 or similar in production!
NXCT_SERVICE_CERTDIRPERMS="${NXCT_SERVICE_CERTDIRPERMS-777}"
if [ -n "$NXCT_SERVICE_CERTDIRPERMS" ]; then
  #chmod -R 600 /certs
  chmod -R $NXCT_SERVICE_CERTDIRPERMS /certs
fi

# Stop Nginx that was running in daemon mode
/usr/sbin/nginx -s stop
echo "Stopping Nginx that was running in daemon mode"

# Sleep a few seconds before starting default Nginx
/bin/sleep 5s

# Start Nginx
echo ""
echo "Restarting Nginx, if no errors appear below, it is ready!"
echo ""
exec /usr/sbin/nginx -g 'daemon off;'