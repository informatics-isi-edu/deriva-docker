#!/bin/bash

log_file=/root/isrd-dev-update.log

touch $log_file

echo "\n$(date): Dev update started." > $log_file

/usr/local/sbin/isrd-stack-mgmt.sh update > $log_file 2>&1

echo "\n$(date): Dev update ended." > $log_file
