FROM alpine:latest

# Install dependencies
RUN apk add --no-cache curl bash

# Copy update script
COPY scripts/ydns_update.sh /usr/local/bin/ydns_update.sh
RUN chmod +x /usr/local/bin/ydns_update.sh

# Set up crontab entry
RUN echo "*/30 * * * * . /run/secrets/ydns.env && /usr/local/bin/ydns_update.sh -V" > /etc/crontabs/root
#RUN echo "*/30 * * * * . /run/secrets/ydns.env && /usr/local/bin/ydns_update.sh >> /var/log/cron.log 2>&1" > /etc/crontabs/root

CMD ["exec", "crond", "-f", "-L", "/dev/stdout"]
