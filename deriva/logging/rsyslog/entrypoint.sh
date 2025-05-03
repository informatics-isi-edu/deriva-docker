#!/bin/bash
set -e

# Start logrotate in background
/usr/local/bin/logrotate.sh &

exec rsyslogd -n
