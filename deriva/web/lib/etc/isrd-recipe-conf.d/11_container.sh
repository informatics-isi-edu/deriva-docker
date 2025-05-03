# Redefine functions as needed for container environment

isrd_stack_all_tasks()
{
    for cmd in clone checkout install deploy enable
    do
        dispatch_cmd "$cmd"
    done
}

isrd_dev_update()
{
    isrd_checkout_code
    isrd_install_code
}

isrd_enable_services()
{
    :
}

restorecon()
{
    :
}

set_selinux_type()
{
    :
}