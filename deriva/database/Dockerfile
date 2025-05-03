# Base: Official Postgres 16 image
FROM postgres:16.8

# Create daemon account users matching deriva webservice users so we can use PEER auth for Postgres
COPY create-users.sh /root
RUN chmod +x /root/create-users.sh
RUN /root/create-users.sh
RUN rm -f /root/create-users.sh
