#!/bin/bash

# define these funcs before library source,
# to allow redefinitions from the library's conf directory

isrd_restart_httpd()
{
    service httpd restart
}

isrd_stack_all_tasks()
{
    for cmd in clone checkout install deploy enable restart
    do
        dispatch_cmd "$cmd"
    done
}

isrd_dev_update()
{
    isrd_checkout_code
    isrd_install_code
    isrd_restart_httpd
}

isrd_stack_extended_cmd()
{
    # this stub just rejects unknown core commands
    # projects can redefine to add commands
    # and revise the usage information
    case "$1" in
        *)
            cat <<EOF
usage: isrd-stack-mgmt.sh <sub-command>...

Where sub-commands are one of these primitives:

  clone --> invokes project's isrd_prepare_repos function
  checkout --> invokes project's isrd_checkout_code function
  install --> invokes project's isrd_install_code function
  deploy --> invokes project's isrd_deploy_services function
  enable --> invokes project's isrd_enable_services function
  restart --> invokes project's isrd_restart_httpd function

or one of these named compounds:

  update --> invokes project's isrd_dev_update function
  all --> as if all preceding were supplied in documented order

The isrd_stack_all_tasks compound runs all primitive commands listed
above from "clone" to "restart". When multiple sub-commands are given,
they are invoked in the order supplied on the command line. This could
cause repeat invocation of the same primitives.

If linked and invoked as "dev-update.sh", this command ignores
arguments and instead runs as if invoked as:

  isrd-stack-mgmt.sh update

EOF
            exit 1
            ;;
    esac
}

# now source the library and its conf directory
. /usr/local/sbin/isrd-recipe-lib.sh

# now the basic shared dispatch logic...

dispatch_cmd()
{
    case "$1" in
        clone) isrd_prepare_repos ;;
        checkout) isrd_checkout_code ;;
        install) isrd_install_code ;;
        deploy) isrd_deploy_services ;;
        enable) isrd_enable_services ;;
        restart) isrd_restart_httpd ;;
        all) isrd_stack_all_tasks ;;
        update) isrd_dev_update ;;
        *)
            # pass unknown subcommands to the project's custom
            # function
            isrd_stack_extended_cmd "$1"
            ;;
    esac
}

invokedas="$(basename "$0")"
if [[ "$invokedas" = "dev-update.sh" ]]
then
    cmds=( update )
else
    cmds=( "$@" )
fi

# run the script allowing multiple commands
for cmd in "${cmds[@]}"
do
    dispatch_cmd "$cmd"
done
