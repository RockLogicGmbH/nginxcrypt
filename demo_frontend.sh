#!/bin/bash
if ! grep -s "DEMO FRONTEND" /usr/share/nginx/html/index.html; then
    sed -i 's/Welcome to nginx!/DEMO FRONTEND<br><br>Welcome to nginx!/g' /usr/share/nginx/html/index.html
fi
exec /usr/sbin/nginx -g 'daemon off;'