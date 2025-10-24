#!/bin/bash

# We MAY use modern bash features in this library script
#

declare -A isrd_dir_chowns
declare -A isrd_dir_chmods
declare -A isrd_dirpat_selinux

declare -A user_uid_data
declare -A user_wheel_data
declare -A user_sshkey_data
declare -A user_sshkey_count

isrd_grant_wheel_users()
{
    # usage; enable_wheel_users username...
    # for safety, only LAST call is remembered
    user_wheel_data=()
    for username in "$@"
    do
        user_wheel_data["$username"]="true"
    done
}

isrd_sshkey()
{
    # usage: sshkey <username> <publickey>
    _index=${user_sshkey_count[$1]:-0}
    user_sshkey_data["${1}_${_index}"]="$2"
    user_sshkey_count["$1"]=$(( ${_index} + 1 ))
}

## load installed recipe config files
for conf in $(ls /etc/isrd-recipe-conf.d/*.sh | LC_ALL=C sort)
do
    if [[ -r "$conf" ]]
    then
        . "$conf"
    fi
done

pattern='^(.*:)?/usr/local/bin(:.*)?'
if [[ ! "$PATH" =~ $pattern ]]
then
    # we need this in our path even if cron left it out...
    # this is where pip3 puts our web service deploy scripts
    PATH=/usr/local/bin:${PATH}
fi

ISRD_PYLIBDIR=$(python3 -c 'import site; print(site.getsitepackages()[1])')

############## utility stuff

ISRD_ADMIN_GROUP=(
    "https://auth.globus.org/3938e0d0-ed35-11e5-8641-22000ab4b42b"
)

error()
{
    cat >&2 <<EOF
$0 error: "$@"
EOF
    exit 1
}


require()
{
    # usage: require cmd [args...]
    # just run command-line and check for success status code
    "$@"
    status=$?
    if [[ $status != 0 ]]
    then
	error Command "($*)" returned non-zero "status=$status"
    fi
}

require_retry()
{
    for trial in {1..5}
    do
	"$@"
	status="$?"
	if [[ "$status" = 0 ]]
	then
	    return 0
	else
	    echo "require_retry: $* returned status $status" >&2
	fi
    done
    error Command "($*)" failed too many times
}

############## system recipe stuff

iptables_rules()
{
    cat <<EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
EOF

    _port=
    _src=
    while [[ $# -gt 0 ]]
    do
	case "$1" in
	    -s)
                if [[ -n "$2" ]]
                then
		    _src="-s $2"
                else
                    _src=
                fi
		shift 2
		;;
	    -tcp)
		_port="$2"
		shift 2

		cat <<EOF
-A INPUT -p tcp -m state --state NEW -m tcp --dport ${_port} ${_src} -j ACCEPT
EOF
		;;
	    # TODO: add -udp support?
	    *)
		cat >&2 <<EOF
ERROR: unhandled iptables rules starting at "$@"
EOF
		exit 1
		;;
	esac
    done
    
    cat <<EOF
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
COMMIT
EOF
}

certbot_enable()
{
    # usage: certbot_enable [name]
    # defaults to using name=$(hostname)
    _name=${1:-$(hostname)}
    
    # this scriptlet assumes you have already installed httpd, mod_ssl,
    # and have manually run certbot once and retained the files

    # 1. start Apache in default state  (ensure /.well-known/acme-challenges allows plain HTTP access!)
    # 2. certbot certonly --webroot -w /var/www/html -d "${name}"

    # YOU NEED TO REPLACE THIS SCRIPT IF USING OTHER DOMAIN NAMES

    [[ -d /home/secrets/letsencrypt ]] || require mkdir /home/secrets/letsencrypt

    # some shorthand
    conf=/etc/httpd/conf.d/ssl.conf
    letsdir=/etc/letsencrypt/live/${_name}

    mv $conf $conf.orig
    sed -e "s|^\(SSLCertificateFile\) .*|\1 $letsdir/fullchain.pem|" \
        -e "s|^\(SSLCertificateKeyFile\) .*|\1 $letsdir/privkey.pem|" \
        -e "s|^#\? *\(SSLCertificateChainFile\) .*|#\1 /path/to/chainfile|" \
        < $conf.orig \
        > $conf
    chmod u+rw,og=r $conf

    systemctl enable certbot-renew.timer

    newscript=/etc/letsencrypt/renewal-hooks/deploy/isrd-secrets-save
    require mkdir -p "$(dirname ${newscript})"
    require cat > $newscript <<EOF
#!/bin/sh

# save results of each renewal to our /home/secrets storage
rsync -au /etc/letsencrypt/. /home/secrets/letsencrypt/.

EOF
    require chmod a+rx $newscript

    newscript=/etc/letsencrypt/renewal-hooks/deploy/httpd-restart
    require mkdir -p "$(dirname ${newscript})"
    require cat > $newscript <<EOF
#!/bin/sh

# restart apache to pick up revised certificate(s)
/usr/sbin/service httpd restart

EOF
    require chmod a+rx $newscript
}

shopt -s extglob

path_matches_prefix()
{
    # args: path prefix

    # reduce any repeating "/" to single "/"
    _path="${1//+(\/)/\/}"
    _prefix="${2//+(\/)/\/}"
    # also strip trailing "/"
    _pat="^${_prefix%%*(/)}(/.*)?$"
    [[ "${_path%%*(/)}" =~ ${_pat} ]]
}

string_matches_prefix()
{
    # args: str prefix
    _len=${#2}
    [[ "${1:0:${_len}}" = "$2" ]]
}

declare -A _chowns
declare -A _chmods
    
set_selinux_type()
{
    type=$1
    file=$2
    semanage fcontext --add --type "$type" "$file" \
      || semanage fcontext --modify --type "$type" "$file" \
	     || error Could not install SE-Linux context "$type" for "$file"
}

isrd_fixup_permissions_onepath()
{
    # usage: isrd_fixup_permissions_onepath path

    # note: we call it "dir" but it might be a file...
    for dir in $(printf "%q\n" "${!_chowns[@]}" | sort)
    do
        if path_matches_prefix "$dir" "$1" && [[ -e "$dir" ]]
        then
            # configured dir is under requested path
            require chown ${_chowns[$dir]} "$dir"
        elif path_matches_prefix "$1" "$dir" && [[ -d "$1" ]] \
                && string_matches_prefix "${_chowns[$dir]}" "-R"
        then
            # requested path is under a recursively configured dir
            require chown ${_chowns[$dir]} "$1"
        fi
    done

    for dir in $(printf "%q\n" "${!_chmods[@]}" | sort)
    do
        if path_matches_prefix "$dir" "$1" && [[ -e "$dir" ]]
        then
            # configured dir is under requested path
            require chmod ${_chmods[$dir]} "$dir"
        elif path_matches_prefix "$1" "$dir" && [[ -d "$1" ]] \
                && string_matches_prefix "${_chmods[$dir]}" "-R"
        then
            # requested path is under a recursively configured dir
            require chmod ${_chmods[$dir]} "$1"
        fi

    done

    for pat in "${!isrd_dirpat_selinux[@]}"
    do
        # BUG: this can miss a middle case where the requested path
        # is longer than the literal prefix of the configured pattern
        # and does not match, while there are possibles suffixes
        # which could complete the path to match the pattern!
        if [[ "$1" =~ $pat ]] || string_matches_prefix "$pat" "$1"
        then
            # requested path matches configured pattern
            # OR requested path prefixes configured pattern
            set_selinux_type "${isrd_dirpat_selinux[$pat]}" "$pat"
            if [[ -d "$1" ]] && [[ ! "$1" = "/" ]]
            then
                restorecon -rv "$1"
            fi
        fi
    done
}

isrd_fixup_permissions()
{
    # args: path...
    #
    # defaults to "/" if no paths are specified
    # otherwise skips rules that do not intersect path(s)

    # reset temporary arrays
    _chowns=()
    _chmods=()
    
    # auto-generate /home/X
    for dir in /home/*
    do
        [[ -d "$dir" ]] || continue
        user="$(basename "$dir")"
        if id "$user" > /dev/null
        then
            _chowns["$dir"]="-R ${user}:"
            _chmods["$dir"]="-R og-w"
            _chmods["${dir}/"]="og-w+x" # trailing / allows a 2nd rule
            _chmods["${dir}/.ssh"]="-R og="
            _chmods["${dir}/.ssh/"]="og+rx"
            _chmods["${dir}/.ssh/authorized_keys"]="og+r"
        else
            # takeover unknown home dirs for sanity
            _chowns["$dir"]="-R root:"
        fi
    done
    
    # copy over existing config
    # these may be more specific/override /home/X above...
    for dir in "${!isrd_dir_chowns[@]}"
    do
        _chowns["$dir"]="${isrd_dir_chowns[$dir]}"
    done
    for dir in "${!isrd_dir_chmods[@]}"
    do
        _chmods["$dir"]="${isrd_dir_chmods[$dir]}"
    done

    # run on specific paths or apply all
    if [[ $# -gt 0 ]]
    then
        for dir in "$@"
        do
            isrd_fixup_permissions_onepath "$1"
        done
    else
        isrd_fixup_permissions_onepath "/"
    fi
}

secrets_restore()
{
    for f in /home/secrets/tls/certs/*.crt
    do
        [[ -r "$f" ]] && install -o root -g root -m a+r "$f" /etc/pki/tls/certs/
    done

    for f in /home/secrets/tls/private/*.key
    do
        [[ -r "$f" ]] && install -o root -g root -m u+r,og= "$f" /etc/pki/tls/private/
    done

    if [[ -d /home/secrets/letsencrypt ]] && [[ -d /etc/letsencrypt ]]
    then
        rsync -avUR /home/secrets/./letsencrypt /etc/./
    fi

    for f in /home/secrets/ssh/*_key
    do
        [[ -r "$f" ]] && install -o root -g root -m u=rw,og= "$f" /etc/ssh/
    done

    for f in /home/secrets/ssh/*_key.pub
    do
        [[ -r "$f" ]] && install -o root -g root -m u=rw,og=r "$f" /etc/ssh/
    done

    # in case the sysadmin messed up selinux context while deploying secrets...
    isrd_fixup_permissions /home/secrets/oauth2
}

secrets_save_ssh()
{
    # this should be run after VM provisioning
    # idempotently saves keys but does not overwrite!
    
    require [ -d /home/secrets ]
    require mkdir -p /home/secrets/ssh

    for f in /etc/ssh/*_key /etc/ssh/*_key.pub
    do
        if [[ -r "$f" ]]
        then
	    if ! [[ -r /home/secrets/ssh/$(basename "$f") ]]
	    then
	        cp -a "$f" /home/secrets/ssh/ && nfound=$(( $nfound + 1 ))
	    fi
        fi
    done
}

isrd_restic_restore_dirs()
{
    # args: snaphost snappaths snapshot pattern...
    #
    # snaphost: passed to restic as -H snaphost
    # snappaths: passed to restic as --path=snappaths
    # snapshot: passed to restic as snapshot ID
    #
    # the snaphost and snappaths help choose
    # which "latest" snapshot to use
    #
    # extract files matching patterns
    # restores to current directory
    args=(
	restore -H "${1}"
	-t "$(pwd)"
	--path="${2}"
    )
    snap="$3"
    shift 3
    for dir in "$@"
    do
	args+=( -i "$dir" )
    done
    args+=( "${snap}" )
    require isrd-restic.sh "${args[@]}"
}

declare -A _users_enabled

SUDO_WHEEL_GROUP=${SUDO_WHEEL_GROUP:-wheel}

isrd_enable_users()
{
    # args: <username>...
    #
    # ENABLES requested usernames
    # DISABLES other usernames defined by our library!
    #
    # so last call "wins"
    _users_enabled=()
    
    while [[ $# -gt 0 ]]
    do
        if [[ "$1" = "root" ]]
        then
            error "Enabling root is not supported"
        fi
        if [[ -z "${user_uid_data[$1]}" ]]
        then
            error "Username '$1' does not have a UID defined in isrd-recipe-conf"
        fi
        _users_enabled["$1"]=true
        shift
    done

    for username in "${!user_uid_data[@]}"
    do
        if [[ "${_users_enabled[$username]}" != "true" ]]
        then
            if id "$username"
            then
                # disable 
                require userdel "$username"
                isrd_fixup_permissions "/home/$username"
            fi
            continue
        fi

        if ! id "$username"
        then
            require useradd -m --uid="${user_uid_data[$username]}" "$username"
        fi

        if [[ "${user_wheel_data[$username]}" = "true" ]]
        then
            require gpasswd -a "$username" ${SUDO_WHEEL_GROUP}
        else
            gpasswd -d "$username" ${SUDO_WHEEL_GROUP}
        fi

        _HOME=$(getent passwd "$username" | cut -f6 -d:)
        if [[ -z "${_HOME}" ]]
        then
	    echo "Could not determine HOME for '$username'"
	    return 1
        fi
        _SSHDIR="${_HOME}/.ssh"
        _HTMLDIR="${_HOME}/public_html"
        _KEYS="${_SSHDIR}/authorized_keys"
    
        require mkdir -p "${_SSHDIR}"
        require touch "${_KEYS}"

        _index=0
        while [[ ${_index} -lt "${user_sshkey_count[$username]:-0}" ]]
        do
            _key="${user_sshkey_data[${username}_${_index}]}"
            grep -q "${_key}" "${_KEYS}" || cat >> "${_KEYS}" <<EOF
${_key}
EOF
            _index=$(( ${_index} + 1 ))
        done
        
        require mkdir -p "${_HTMLDIR}"
        
        isrd_fixup_permissions "${_HOME}"
        
        require restorecon -rv "${_HOME}"

        # continue with next username...
        shift
    done
}


############## deriva stack management

DEVUSER=isrddev

isrddev_repo_run()
{
    id "$DEVUSER" > /dev/null || error "Missing required account '$DEVUSER'"

    pattern='^[^/]+$'
    if [[ "$1" =~ $pattern ]]
    then
        _dir="/home/${DEVUSER}/$1"
    else
        _dir="$1"
    fi

    shift

    # don't switch user, assume command does it internally as needed
    require cd "${_dir}"
    require "$@"
}

# we do fetch ; checkout to get latest heads from upstream
git_checkout()
{
    id "$DEVUSER" > /dev/null || error "Missing required account '$DEVUSER'"
    # usage: repodir [ checkout-arg... ]
    pattern='^[^/]+$'
    if [[ "$1" =~ $pattern ]]
    then
        # short form only has final dirname
        _repodir="/home/${DEVUSER}/$1"
    else
        # assume full path if it contains a /
        _repodir="$1"
    fi

    require cd "${_repodir}"
    shift
    require chown -R ${DEVUSER}: .
    # NOTE: changing dir in the command and using `-` login mode needed
    # otherwise we get wrong umask and/or wrong working dir for git commands
    require_retry su -c "cd \"${_repodir}\" && git fetch" - ${DEVUSER}
    if [[ "$#" -gt 0 ]]
    then
	args=$(printf ' "%s"' "$@")
    else
	args="origin/master"
    fi
    require su -c "cd \"${_repodir}\" && git checkout -f $args" - ${DEVUSER}
}

git_clone_idempotent()
{
    id "$DEVUSER" > /dev/null || error "Missing required account '$DEVUSER'"
    # usage:  git_clone_idempotent  repo_url
    require [ $# -eq 1 ]

    pattern1='^[^/]+[.]git$'
    pattern2='^[^/:]+/[^/]+[.]git$'

    if [[ "$1" =~ $pattern1 ]]
    then
        # short form for reponame.git (in our org)
        repo="https://github.com/informatics-isi-edu/$1"
    elif [[ "$1" =~ $pattern2 ]]
    then
        # short form for orgname/reponame.git
        repo="https://github.com/$1"
    else
        # otherwise assume it's a full URL
        repo="$1"
    fi

    # we do default clone which names dir after repo
    repodir=$(basename "$repo" .git)

    if [[ -e "/home/${DEVUSER}/${repodir}" ]]
    then
	# if repodir exists, validate that it seems like correct repo
	require [ -d "/home/${DEVUSER}/${repodir}" ]
	require grep "^[[:space:]]*url = *$repo" "/home/${DEVUSER}/${repodir}/.git/config"
    else
	# only clone if it is absent
	require_retry su -c "git clone $repo" - ${DEVUSER}
    fi
}

cron_run()
{
    # usage: jobname cmd [ cmd... ]
    jobname="$1"
    shift

    (
	cat <<EOF
$0 cron_run $jobname started $(date -Iseconds)
EOF

	status=0
	for cmd in "$@"
	do
	    cat <<EOF

> running $cmd
EOF
	    $cmd
	    status="$?"
	    if [[ "$status" -ne 0 ]]
	    then
		cat <<EOF
error: $0 $cmd returned $status

EOF
		exit $status
	    else
		cat <<EOF
: status 0 from $cmd
EOF
	    fi
	done
    ) > /root/isrd-cron-${jobname}.log 2>&1
    status=$?

    if [[ $status -ne 0 ]]
    then
	cat /root/isrd-cron-${jobname}.log
	echo "aborting on status $status"
	exit $status
    fi
}

pgid()
{
    line=$(su -c "psql -q -t -A -c \"select * from pg_roles where rolname = '$1'\"" - postgres)
    status=$?
    [[ $status -eq 0 ]] || return $status
    [[ -n "$line" ]] || return 1
    echo "$line"
    return 0
}

pgdbid()
{
    line=$(su -c "psql -q -t -A -c \"select * from pg_database where datname = '$1'\"" - postgres)
    status=$?
    [[ $status -eq 0 ]] || return $status
    [[ -n "$line" ]] || return 1
    echo "$line"
    return 0
}

isrd_init_postgres()
{
    # prepare empty database cluster for DB restoration
    found=
    for ver in $1 {18..12}
    do
        new_binary="/usr/pgsql-${ver}/bin/postgresql-${ver}-setup"
        if [[ -x ${new_binary} ]]
        then
          ${new_binary} initdb
          require isrd_fixup_permissions /var/lib/pgsql/ /usr/pgsql-${ver}
          systemctl start postgresql-${ver}
          found=true
          break
        fi
    done
    if [[ -z "$found" && -x "/usr/bin/postgresql-setup" ]]
    then
      /usr/bin/postgresql-setup --initdb
      systemctl start postgresql
    fi

    pgid webauthn || require su - postgres -c 'createuser -D webauthn'
    pgid ermrest || require su - postgres -c 'createuser -d ermrest'
    pgid hatrac || require su - postgres -c 'createuser -D hatrac'

}

isrd_restore_db()
{
    # usage: isrd_restore_db user owner dbname path.sql.gz
    cat >&2 <<EOF
isrd_restore_db user=$1 owner=$2 dbname=$3 path=$4
EOF

    require [ "$#" -eq 4 ]
    require id "$1"
    require pgid "$2"
    require [ -r "$4" ]
    
    require su - "$1" -c "createdb -O $2 $3"
    require su - "$2" -c "zcat $4 | psql $3"

    require su - "$2" -c "psql $3" <<EOF
DO \$\$
BEGIN

IF (SELECT True FROM information_schema.schemata WHERE schema_name = '_ermrest') THEN
   PERFORM _ermrest.model_change_event();
END IF;

END;
\$\$ LANGUAGE plpgsql;
EOF
}

isrd_insert_ermrest_registry() {
    db="$1"
    host="$2"

    if [ -z "$db" ]; then
        echo "usage: isrd_insert_ermrest_registry <dbname> [host]" >&2
        return 2
    fi

    if [ -n "$host" ]; then
        json=$(printf '{"type":"postgres","dbname":"%s","host":"%s"}' "$db" "$host")
    else
        json=$(printf '{"type":"postgres","dbname":"%s"}' "$db")
    fi

    su -c "psql" - ermrest <<EOF
INSERT INTO ermrest.registry(descriptor) VALUES ('$json');
EOF
}


################ git tasks

# these URLs used to be wrapped in functions
# instead, just call `git_clone_idempotent <URL>` directly in your scripts!

# public ISRD repos support shorthand of bare "reponame.git"
#
# git_clone_idempotent webauthn.git
# git_clone_idempotent ermrest.git
# git_clone_idempotent hatrac.git
# git_clone_idempotent ermresolve.git
# git_clone_idempotent deriva-web.git
# git_clone_idempotent deriva-py.git
# git_clone_idempotent ermrestjs.git
# git_clone_idempotent chaise.git
# ...

# another shorthand supports "orgname/reponame.git":
#
# git_clone_idempotent InsightSoftwareConsortium/ITK.git
# ...

# private repos need full URLs to change from default http URL style
#
# git_clone_idempotent git@github.com:informatics-isi-edu/rbk-project.git
# ...

# python modules used to be wrapped in functions
# Makefile modules used to be wrapped in functions
#
# now just have one generic helper to concisely changedir and run a command
# knowing that we cloned to /home/${DEVUSER}/${reponame}
#
# standard components:
#
# isrddev_repo_run webauthn   make install
# isrddev_repo_run ermrest    pip3 install --upgrade .
# isrddev_repo_run hatrac     pip3 install --upgrade .
# isrddev_repo_run ermresolve pip3 install --upgrade .
# isrddev_repo_run deriva-py  pip3 install --upgrade .
# isrddev_repo_run deriva-web make install
# isrddev_repo_run ermrestjs  make root-install
# isrddev_repo_run chaise     make root-install

# other project-specific installation rules need to be refactored and
# not placed back in this core library!


repair_hatrac_db_name_quoting()
{
    require su - hatrac -c 'psql hatrac' <<EOF

CREATE OR REPLACE FUNCTION hatrac_fix_quoting(hname text) RETURNS text AS \$\$
DECLARE
  inp bytea;
  res text[];
  val int;
BEGIN
  -- setup array with same indexing as the input bytea bytes
  inp := convert_to(hname, 'UTF8');
  res := array_fill(''::text, ARRAY[octet_length(inp)], ARRAY[0]);

  FOR idx IN 0..(octet_length(inp) - 1)
  LOOP
    val := get_byte(inp, idx);
    IF (val >= 97 AND val <= 122)    -- [a-z]
       OR (val >= 65 AND val <= 90)  -- [A-Z]
       OR (val >= 48 AND val <= 57)  -- [0-9]
       OR (val = ANY( ARRAY[ 45, 46, 47, 95, 126 ])) -- [-./_~]
    THEN
       -- these values can be passed literally
       res[idx] := CHR(val);
    ELSE
       -- these need to be URL-escaped
       res[idx] := '%' || upper(lpad(to_hex(val), 2, '0'));
    END IF;
  END LOOP;

  RETURN array_to_string(res, '');
END;
\$\$ LANGUAGE plpgsql;

UPDATE name
SET name = hatrac_fix_quoting(name)
WHERE name != hatrac_fix_quoting(name);

EOF
}
