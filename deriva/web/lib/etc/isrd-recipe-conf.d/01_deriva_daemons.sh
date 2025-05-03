

########### fix permissions config

# these can be re-applied at various points in recipes
# to compensate for changed UID/GID mappings etc.

isrd_dir_chowns=(
    # [/home/X]="X:" will be added HERE automatically
    [/etc/isrd-recipe-conf.d/]="-R root:root"
    [/var/lib/pgsql]="-R postgres:postgres"
    [/var/www/hatrac]="-R hatrac:apache"
    [/var/www/deriva]="-R deriva:apache"
    [/home/secrets/oauth2]="-R root:apache"
    [/home/secrets/restic]="-R root:root"
    # if desired, append more rules...
)

isrd_dir_chmods=(
    # [/home/X]="og-w" will be added HERE automatically
    [/etc/isrd-recipe-conf.d]="-R u=rw,og=r"
    [/etc/isrd-recipe-conf.d/]="u=rwx,og=rx"
    [/etc/sysconfig/iptables]="u=rw,og="
    [/home/secrets/restic]="og="
    [/home/secrets/restic/isrd-restic.conf]="og="
    [/home/secrets/oauth2]="-R ug=r,o="
    [/home/secrets/oauth2/]="ug=rx,o="
    # if desired, append more rules...
)

isrd_dirpat_selinux=(
#    ["/usr/local/etc/oauth2/discovery_.*[.]json"]=httpd_sys_content_t
#    ["/home/secrets/oauth2/client_secret_.*[.]json"]=httpd_sys_content_t
#    ["/home/webauthn/webauthn_config[.]json"]=httpd_sys_content_t
#    ["/home/hatrac/hatrac_config[.]json"]=httpd_sys_content_t
#    ["/home/ermrest/ermrest_config[.]json"]=httpd_sys_content_t
#    ["/home/ermresolve/ermresolve_config[.]json"]=httpd_sys_content_t
#    ["/home/hatrac/.*_config[.]json"]=httpd_sys_content_t
#    ["/home/hatrac/.aws(/.*)?"]=httpd_sys_content_t
#    ["/var/www/hatrac(/.*)?"]=httpd_sys_rw_content_t
#    ["/home/deriva/.aws(/.*)?"]=httpd_sys_rw_content_t
#    ["/home/deriva/.bdbag(/.*)?"]=httpd_sys_rw_content_t
#    ["/home/deriva/.deriva(/.*)?"]=httpd_sys_rw_content_t
#    ["/home/deriva/conf.d(/.*)?"]=httpd_sys_rw_content_t
#    ["/home/deriva/deriva_config.json"]=httpd_sys_rw_content_t
#    ["/tmp/\.s\.PGSQL\.[0-9]+.*"]=postgresql_tmp_t
#    # if desired, append more rules...
)

#case "$(cat /etc/redhat-release 2>/dev/null)" in
#    Fedora*release*4*)
#        # this is needed for Fedora 40+?
#        isrd_dirpat_selinux["/run/postgresql\.s\.PGSQL\.[0-9]+.*"]=postgresql_tmp_t
#        ;;
#    *)
#        # this is needed for Fedora 38 and RHEL 9.x?
#        isrd_dirpat_selinux["/var/run/postgresql\.s\.PGSQL\.[0-9]+.*"]=postgresql_tmp_t
#        ;;
#esac

#for pgver in {18..12}
#do
#   isrd_dirpat_selinux["/usr/pgsql-${pgver}/bin/(initdb|postgres)"]=postgresql_exec_t
#   isrd_dirpat_selinux["/var/lib/pgsql/${pgver}/pgstartup[.]log"]=postgresql_log_t
#   isrd_dirpat_selinux["/var/lib/pgsql/${pgver}/data(/.*)?"]=postgresql_db_t
#done
