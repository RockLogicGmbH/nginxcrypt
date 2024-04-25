#!/bin/bash

# Define default host and frontend/backend proxy (used in case none was given by environment vars)
DEFAULT_NXCT_SERVICE_HOST="localhost"
DEFAULT_NXCT_SERVICE_FRONTEND_TARGET="frontend:80"
DEFAULT_NXCT_SERVICE_BACKEND_TARGET="backend:80"

# If no NXCT_SERVICE_HOST was specified and DEFAULT_NXCT_SERVICE_HOST is set to "localhost" or "127.0.0.1":
# True = Accept connection from both, 127.0.0.1 and localhost
# False = Accept connection only from the given host
DEFAULT_NXCT_SERVICE_ALLOW_LOCAL_HOST_AND_ADDR=true

# Define a default key length for the certificate, and use the parameter if set
keyLength=4096
if [ -n "$NXCT_SERVICE_KEYLENGTH" ]; then
  keyLength=$NXCT_SERVICE_KEYLENGTH
fi

# Should we execute everything on LE's staging platform?
test=""
if [ -n "$NXCT_SERVICE_DRYRUN" ]; then
  test="--test"
fi

# Define a default DH params length, and use the parameter if set
# 1024 length is set for test purposes only, please set it to 2048 at least!
dhParamLength=1024
if [ -n "$NXCT_SERVICE_DHPARAM" ]; then
  dhParamLength=$NXCT_SERVICE_DHPARAM
fi

# Read defined services
services=$(env | grep NXCT_SERVICE_HOST_ | cut -d "=" -f1 | sed 's/^NXCT_SERVICE_HOST_//')

# Check if at least one NXCT_SERVICE_HOST_$service exists
hosts_exist=false
for service in $services
do
  host="NXCT_SERVICE_HOST_$service"
  if [ ! -z "${!host}" ]; then
    hosts_exist=true
    break
  fi
done

# Generate defaults if no NXCT_SERVICE_HOST_$service exists
if [ "$hosts_exist" = false ]; then
  export NXCT_SERVICE_HOST_1="$DEFAULT_NXCT_SERVICE_HOST"
  export NXCT_SERVICE_FRONTEND_TARGET_1="$DEFAULT_NXCT_SERVICE_FRONTEND_TARGET"
  export NXCT_SERVICE_BACKEND_TARGET_1="$DEFAULT_NXCT_SERVICE_BACKEND_TARGET"
  if [ "$DEFAULT_NXCT_SERVICE_ALLOW_LOCAL_HOST_AND_ADDR" = true ]; then
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
if [ -n "$NXCT_SERVICE_DELTEOUTDATEDCERTS" ]; then
  for dir in /certs/*/; do
    # Get the basename of the directory
    dir_basename=$(basename "$dir")
    exists=false
    for service in $services
    do
      host="NXCT_SERVICE_HOST_$service"
      name=${!host}
      if [ "$dir_basename" == "$name" ]; then
        exists=true
        break
      fi
    done
    if [ $exists = false ]; then
      if [ -n "$NXCT_SERVICE_DRYRUN" ]; then
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
  # if [[ ! -d "/certs/${!host}"  || ! -s "/certs/${!host}/cert.pem" ]]; then # only generates a new self-signed if cert.pem not empty
  if [[ ! -d "/certs/${!host}"  || ! -f "/certs/${!host}/cert.pem" ]]; then # only generates a new self-signed if cert.pem does not exist
    echo ""
    echo "Generating a self-signed certificate for ${!host}..."
    certSubj="/C=EU/ST=My State/L=My City/O=My Organization/OU=My Domain/CN=${!host}"
    if [ -n "${!subj}" ]; then
      certSubj=${!subj}
    fi
    mkdir -vp /certs/${!host}
    /usr/bin/openssl genrsa -out /certs/${!host}/key.pem 1024
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

# Generate the DH params file if it does not exist
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