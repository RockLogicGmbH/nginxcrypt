# NginxCrypt

Dockerized Nginx (reverse proxy) with embedded Let's Encrypt certificates.

## Details

A Docker container which embeds an Nginx by default as reverse-proxy, linked with Let's Encrypt (using [acme.sh](https://github.com/acmesh-official/acme.sh)) for SSL/TLS certificates.

The Nginx configuration is purposedly user-defined, so you can set it just the way you want, tought base templates are setup by default.

You can find examples below.

## How does it work?

The image is based upon the official Nginx repository, using the alpine version (`nginx:alpine`).

[acme.sh](https://github.com/acmesh-official/acme.sh) is installed, and certificates are generated/requested during the first start.

First of all, self-signed certificates are generated, so Nginx can start with your SSL/TLS configuration and privte hosts are also protected with the self-signed certs.

Then, [acme.sh](https://github.com/acmesh-official/acme.sh) is used to requested LE-signed certificates, which will replace the self-signed ones if the given domain is publicly avalable on the host where the container is started.

**Since the certificates will be stored in `/certs`, be sure to write your Nginx configuration file(s) accordingly!**

This counts of course only if you want to write your own confuguration files at all (which is not needed by default).

However, the configuration files in `/conf` will be placed in `/etc/nginx/conf.d` in the container.  
If you do not want to use any `NXCT_SERVICE_FRONTEND_TARGET_N`, `NXCT_SERVICE_BACKEND_TARGET_N` and `NXCT_SERVICE_PROXY_N` environment variables at all, and instead you want to definine only your own configuration files for the sepcified hosts, you can set the `conf` volume in read only (`:ro`) mode.

## Production

To run the NginxCrypt application in production:

1. Install Docker (optionally with [this](https://github.com/daverolo/helpers/blob/main/global/installdocker.sh) helper script)
2. Download the [docker-compose.yaml](./docker-compose.yaml) file into a newly created and empty directory
3. Download the [.env.example](./.env.example) file as `.env` into the same directory.
4. Download the [demo_frontend.sh](./demo_frontend.sh) into the same directory.
5. Download the [demo_backend.sh](./demo_backend.sh) into the same directory.
6. Set `NXCT_SERVICE_HOST_1` in `.env` to the IP address of your machine.
7. Run the app via `sudo docker compose up -d`
8. Monitor the app via `sudo docker compose logs -f`
9. Stop the app via `sudo docker compose down`

The steps above will run a Nginx reverse proxy using the `rocklogicgmbh/nginxcrypt:latest` Docker image with a demo frontend available thru https://MACHINE_IP.

If you wanna go for the advanced example that also has a demo backend available thru https://MACHINE_IP/api, just specify `NXCT_SERVICE_FRONTEND_TARGET_1=frontend:80` **and** `NXCT_SERVICE_BACKEND_TARGET_1=backend:80` in the `.env` file and run `sudo docker compose down ; sudo docker compose up -d`.

Self-signed SSL-certificates are auto created in `./volumes/proxy/certs` and Nginx configuration files are auto created in `./volumes/proxy/conf`.

If that worked properly, change `NXCT_SERVICE_HOST_1` in `.env` to the domain that points with an DNS A-record to your machine and run:

```
sudo docker compose down ; sudo docker compose up -d
```

This will automatically generate Let's Encrypt certificates for your domain if the A-record is pointed properly. However, the Nginx reverse proxy is still forwarding to the demo frontend which should be available now thru https://YOUR_DOMAIN (respectively https://YOUR_DOMAIN/api for the backend).

Now it's time to read further and continue the detailed [configuration](#configuration) to point your reverse proxy to the target of your choice using `NXCT_SERVICE_PROXY_N` or `NXCT_SERVICE_FRONTEND_TARGET_N` and `NXCT_SERVICE_BACKEND_TARGET_N` config [options](#options).

## Configuration

The NginxCrypt application [options](#options) must be configured thru [environment variables](#environment-variables).

### Options

| Name                              | Default       | Required | Description                                                              |
| --------------------------------- | ------------- | -------- | ------------------------------------------------------------------------ |
| NXCT_SERVICE_KEYLENGTH            | 4096          | No       | Key length[1] of your Let's Encrypt certificates                         |
| NXCT_SERVICE_EMAIL                | ""            | No       | Optional e-mail address used to register with ZeroSSL                    |
| NXCT_SERVICE_DHPARAM              | 1024[2]       | No       | Diffie-Hellman parameters key length (Generation can use much time![3])  |
| NXCT_SERVICE_DRYRUN               | false         | No       | Set true to use the staging Let's Encrypt environment during your tests. |
| NXCT_SERVICE_DELTEOUTDATEDCERTS   | false         | No       | Set true to delete previously generated certs of none existent hosts     |
| NXCT_SERVICE_CERTDIRPERMS         | 777[4]        | No       | Permissions of the directory where certs are stored                      |
| NXCT_SERVICE_HOST_N               | ""            | No       | Domain the certs should be created for (count up "N", start with 1)      |
| NXCT_SERVICE_PROXY_N[5]           | "frontend:80" | No       | Any proxy target associated to NXCT_SERVICE_HOST_N (for "min" template)  |
| NXCT_SERVICE_FRONTEND_TARGET_N[6] | "frontend:80" | No       | Frontend target associated to NXCT_SERVICE_HOST_N (for "api" template)   |
| NXCT_SERVICE_BACKEND_TARGET_N[6]  | "backend:80"  | No       | Backend target associated to NXCT_SERVICE_HOST_N (for "api" template)    |

> [1]: 1024, 2048, 4096, ec-256, ec-384, ec-521 [not supported by LE yet], etc.

> [2]: 1024 length for Diffie-Hellman parameters key is set for test purposes only, please set it to 2048 at least!

> [3]: Be aware that generation of the Diffie-Hellman parameters key can take much time, **way more than just a couple minutes**.

> [4]: 777 is for test purposes only, please set it to 600 or similar restrictive in production!

> [5]: If `NXCT_SERVICE_PROXY_N` is defined the "min" template is **enforced**.

> [6]: If `NXCT_SERVICE_FRONTEND_TARGET_N` **and** `NXCT_SERVICE_BACKEND_TARGET_N` is defined the "api" template is used.

> All option variables are case-insensitive

If neither `NXCT_SERVICE_HOST_N` nor `NXCT_SERVICE_PROXY_N` or `NXCT_SERVICE_FRONTEND_TARGET_N`/`NXCT_SERVICE_BACKEND_TARGET_N` is defined a default configuration for https://localhost and https://localhost/api is created automatically.

Under the hood there is also one more key `NXCT_SERVICE_SUBJ_`: The self-signed certificate subject of `NXCT_SERVICE_HOST_N`. The expected format is the following: `/C=Country code/ST=State/L=City/O=Company/OU=Organization/CN=your.domain.tld`. It's not really useful, but still, it's there as a easter egg.

### Config file

By default the NginxCrypt application attempts to read the configuration from an `.env` file where you add the [config options](#options).

Example `.env.example` (see [.env.example](./.env.example)):

```
# CONFIG ENV FILE
# NXCT_SERVICE_KEYLENGTH=ec-384
# NXCT_SERVICE_EMAIL=your@email.tld
# NXCT_SERVICE_DHPARAM=2048
# NXCT_SERVICE_DRYRUN=true
# NXCT_SERVICE_DELTEOUTDATEDCERTS=false
# NXCT_SERVICE_CERTDIRPERMS=777
# NXCT_SERVICE_HOST_1=min.template.public-domain.tld
# NXCT_SERVICE_PROXY_1=frontend:80
# NXCT_SERVICE_HOST_2=api.template.public-domain.tld
# NXCT_SERVICE_FRONTEND_TARGET_2=frontend:80
# NXCT_SERVICE_BACKEND_TARGET_2=backend:80
# NXCT_SERVICE_HOST_3=onemore.api.template.public-domain.tld
# NXCT_SERVICE_FRONTEND_TARGET_3=frontend:80
# NXCT_SERVICE_BACKEND_TARGET_3=backend:80
```

The config file is read from the `.env` file specified in the `docker-compose.yaml` for the `proxy` container which is by default the .env file in your NginxCrypt application root.

### Environment variables

You can also configure the NginxCrypt application [options](#options) by environment variables. They will overwrite all identical [options](#options) that are already defined in the [config file](#config-file).

For example, to specify `NXCT_SERVICE_HOST_1` as environment variable:

```
export NXCT_SERVICE_HOST_1="min.template.public-domain.tld"
sudo docker compose down ; sudo docker compose up -d proxy
```

To remove the environment variable:

```
unset NXCT_SERVICE_HOST_1
sudo docker compose down ; sudo docker compose up -d proxy
```

### Volumes

Two volumes (by default located in `./volumes/proxy` on the host system) are used:

- `/certs`: all the certificates will be stored here (including dhparam.pem). You do not need to put anything by yourself, the container will do it itself. However, you need to make sure the volume is mapped to your physical disk or the certificates will be generated on each restart of the container!

- `/conf`: place your optional/additional Nginx configuration file(s) here in format `name[A-Z0-9].conf` (e.g: "server27.conf"). Do not use sole numeric definitions like "0.conf" since they are reserved for auto-generated configs, the rest is up to you.

Please note that neither SSL/TLS certificates nor Nginx configuration file(s) need to be created or modified by yourself. It usually works out of the box but you can however [adjust them for your needs](#nginx-configuration-notes).

## Development usage

Prequisites:

- Install [Docker Desktop](https://docs.docker.com/get-docker/) on your local OS.
- Optionally install [VSCode](https://code.visualstudio.com/)
  > If you are using Windows, we strongly recommend you to [use Git Bash as terminal inside VSCode](https://www.geeksforgeeks.org/how-to-integrate-git-bash-with-visual-studio-code/)!

Fetch the repo and move to the application root directory:

```
git clone <path>
cd nginxcrypt
```

Build the container:

```
docker compose build proxy
```

Start:

```
sudo docker compose up -d
```

> You can also build the proxy container on start via `sudo docker compose up -d --build`

Open demo frontend thru NginxCrypt reverse proxy:

- https://localhost

Open demo backend thru NginxCrypt reverse proxy:

- https://localhost/api

Stop:

```
sudo docker compose down
```

## Example

Here is an example with three domains using different templates:

```yaml
version: "3.7"
services:
  proxy:
    container_name: proxy
    image: rocklogicgmbh/nginxcrypt:latest
    restart: always
    ports:
      - "80:80"
      - "443:443"
    # tty: true # only needed for zerossl if NXCT_SERVICE_EMAIL is given (currently disabled anyway!)
    env_file: .env
    volumes:
      - ./.volumes/proxy/certs:/certs
      - ./.volumes/proxy/conf:/conf
    environment:
      # - NXCT_SERVICE_KEYLENGTH=ec-384
      # - NXCT_SERVICE_EMAIL=your@email.tld
      # - NXCT_SERVICE_DHPARAM=2048
      # - NXCT_SERVICE_DRYRUN=true
      # - NXCT_SERVICE_DELTEOUTDATEDCERTS=true
      # - NXCT_SERVICE_CERTDIRPERMS=600
      # - NXCT_SERVICE_HOST_1=min.template.public-domain.tld
      # - NXCT_SERVICE_PROXY_1=frontend:80
      # - NXCT_SERVICE_HOST_2=api.template.public-domain.tld
      # - NXCT_SERVICE_FRONTEND_TARGET_2=frontend:80
      # - NXCT_SERVICE_BACKEND_TARGET_2=backend:80
      # - NXCT_SERVICE_HOST_3=onemore.api.template.public-domain.tld
      # - NXCT_SERVICE_FRONTEND_TARGET_3=frontend:80
      # - NXCT_SERVICE_BACKEND_TARGET_3=backend:80
    extra_hosts:
      - "host.docker.internal:host-gateway" # required on Linux!
```

However, if you check the [docker-compose.yaml](./docker-compose.yaml) file of this repo you have a fully working example.

## Notes

Some additional configuration and usage notes.

### Default hosts

If no `NXCT_SERVICE_HOST_N` is defined there will be default self signed certs generated for `localhost` and `127.0.0.1`.

### Access restrictions

By default only domains that are defined via `NXCT_SERVICE_HOST_N` are accessible. Other domains pointing to the same host will be denied with a 406 HTTP error. If the host is requested via undefined IP address it will be denied with a 403 HTTP error.

### Forwarding rules

All requests to HTTP will be redirected to HTTPS.

### WebSockets

WebSocket support is enabled by default.

### Nginx configuration notes

**Since the certificates will be stored in `/certs`, be sure to write your Nginx configuration file(s) accordingly!**

This counts of course only if you want to write your own confuguration files at all (which is not needed by default).

However, the configuration files in `/conf` will be placed in `/etc/nginx/conf.d` in the container.  
If you do not want to use any `NXCT_SERVICE_FRONTEND_TARGET_N`, `NXCT_SERVICE_BACKEND_TARGET_N` and `NXCT_SERVICE_PROXY_N` environment variables at all, and instead you want to definine only your own configuration files for the sepcified hosts, you can set the `conf` volume in read only (`:ro`) mode.

### Physical host targets

The Nginx reverse proxy is running in a Docker container. If you want to use targets on your host machine you can use `host.docker.internal[:<port>]` as definition for `NXCT_SERVICE_FRONTEND_TARGET_N`, `NXCT_SERVICE_FRONTEND_TARGET_N` or `NXCT_SERVICE_PROXY_N`.

Note that this requires `extra_hosts` defined for the service in your `docker-compose.yaml` on Linux:

- https://stackoverflow.com/a/58053620
- https://stackoverflow.com/a/62431165
- https://stackoverflow.com/a/67158212

### Cert renewals

SSL certificates issued by Let's Encrypt are automatically renewed every 60 days. This is done by the [acme.sh](https://github.com/acmesh-official/acme.sh) script, which is installed in the container.

Self-signed certs won't be renewed since you need to add an exception in your browser anyway. However, you can of course just delete specific self-signed certs and restart the container in case you want to enforce a renewal.

# Credits

The idea, motivation and base code/docs for this app was taken from:

- https://github.com/bh42/docker-nginx-reverseproxy-letsencrypt

We mainly adjusted and enhanced it for our own use cases.
