ARG OPENRESTY_RUNTIME_IMAGE=openresty/openresty:1.27.1.2-0-bookworm-fat
FROM ${OPENRESTY_RUNTIME_IMAGE}

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY litewaf-realip.conf /usr/local/openresty/nginx/conf/litewaf-realip.conf
COPY lua /usr/local/openresty/nginx/lua
COPY conf /etc/litewaf
COPY docker-entrypoint.sh /usr/local/bin/litewaf-entrypoint.sh
COPY litewaf-reload.sh /usr/local/bin/litewaf-reload.sh

RUN chmod +x /usr/local/bin/litewaf-entrypoint.sh /usr/local/bin/litewaf-reload.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/litewaf-entrypoint.sh"]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
