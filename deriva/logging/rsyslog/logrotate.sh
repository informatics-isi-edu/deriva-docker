#!/bin/bash

trap "echo 'Shutting down logrotate loop'; exit" SIGTERM SIGINT

while true; do
  /usr/sbin/logrotate /etc/logrotate.d/rsyslog
  sleep 900
done
