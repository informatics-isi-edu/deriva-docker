#!/bin/bash
set -e

source /usr/local/lib/utils.sh
source /usr/local/lib/runtime.sh

# Suppress cert verify warnings in test environments
if [[ "$DEPLOY_ENV" != "prod" && "$DEPLOY_ENV" != "staging" && "$DEPLOY_ENV" != "dev" ]]; then
  export PYTHONWARNINGS="ignore:Unverified HTTPS request"
fi

# set default command
if [ $# -eq 0 ]; then
  set -- gunicorn --workers 1 --threads 4 --bind 0.0.0.0:8999 deriva.web.groups.wsgi:application
fi

# run processes
start_rsyslog
start_main_process "$@"
monitor_loop