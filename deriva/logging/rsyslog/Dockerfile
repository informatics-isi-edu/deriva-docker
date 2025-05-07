FROM debian:bookworm

RUN apt-get update && \
    apt-get install -y rsyslog logrotate --no-install-recommends && \
    apt-get clean

COPY rsyslog.conf /etc/rsyslog.conf
COPY logrotate.conf /etc/logrotate.d/rsyslog
COPY logrotate.sh /usr/local/bin/logrotate.sh
RUN chmod 0644 /etc/logrotate.d/rsyslog

RUN chmod +x /usr/local/bin/logrotate.sh && \
    mkdir -p /var/log/shared

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0644 /entrypoint.sh
