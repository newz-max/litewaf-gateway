ARG OPENRESTY_RUNTIME_IMAGE=openresty/openresty:1.27.1.2-0-bookworm-fat
FROM ${OPENRESTY_RUNTIME_IMAGE}

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY lua /usr/local/openresty/nginx/lua
COPY conf /etc/litewaf

EXPOSE 8080

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
