FROM nginx:alpine

VOLUME ["/certs", "/conf"]

RUN apk add netcat-openbsd bc curl wget git bash openssl libressl

RUN cd /tmp/ && git clone https://github.com/acmesh-official/acme.sh.git

RUN cd /tmp/acme.sh/ && ./acme.sh --install && rm -rf /tmp/acme.sh

WORKDIR /root/.acme.sh/

RUN mkdir -vp /var/www/html/.well-known/acme-challenge/

COPY entrypoint.sh /root/.acme.sh/

COPY *.template /tmp

RUN chmod +x /root/.acme.sh/entrypoint.sh

RUN rm -rf /etc/nginx/conf.d && ln -s /conf /etc/nginx/conf.d

RUN /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

EXPOSE 80 443

ENTRYPOINT [ "/root/.acme.sh/entrypoint.sh" ]