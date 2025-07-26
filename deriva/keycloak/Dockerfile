FROM deriva/base AS deriva-base

FROM quay.io/keycloak/keycloak:latest

USER root

# Copy shared library scripts
COPY --from=deriva-base /usr/local/lib/*.sh /usr/local/lib/

# Copy entrypoint script and template
COPY config/realm-export.json.in /opt/realm-export.json.in
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

USER root
RUN /opt/keycloak/bin/kc.sh build --http-relative-path=/auth --health-enabled=true --metrics-enabled=true --db=dev-file

# Set entrypoint
ENTRYPOINT ["/opt/entrypoint.sh"]
USER 1000
