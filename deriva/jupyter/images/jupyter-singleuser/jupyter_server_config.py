
c = get_config()

# make your user venv the default
c.MultiKernelManager.default_kernel_name = "deriva-dev-uv"
# don't synthesize a native 'python3' kernel
c.KernelSpecManager.ensure_native_kernel = False
c.KernelSpecManager.whitelist = ["deriva-dev-uv"]
c.ServerApp.shutdown_no_activity_timeout = 1800
c.ServerApp.terminado_settings = {
    "shell_command": ["/bin/bash", "-l"]
}
