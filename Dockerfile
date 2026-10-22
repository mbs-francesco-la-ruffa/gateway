# The gateway: Caddy at a fixed version, plus the script that writes its configuration and the
# maintenance page from variables at every start (README.md). Dependabot proposes the new Caddy.
FROM caddy:2.11.7-alpine

LABEL org.opencontainers.image.source="https://github.com/mbs-francesco-la-ruffa/gateway" \
      org.opencontainers.image.description="Gateway for Railway projects: routes the public domains over the private network and shows a maintenance page." \
      org.opencontainers.image.licenses="UNLICENSED"

COPY --chmod=0755 gateway.sh /usr/local/bin/gateway
COPY --chmod=0644 page.html /usr/share/gateway/page.html

ENV PORT=8080
# 8080 on Railway; 80 and 443 with TLS on, away from Railway. /data (a volume of the base image) keeps
# the certificates and the maintenance switch file.
EXPOSE 8080 80 443

# No start command needed on Railway: the image starts the gateway by itself. The base image's CMD
# (caddy run) is cleared, or it would reach the script as arguments.
ENTRYPOINT ["/usr/local/bin/gateway"]
CMD []
