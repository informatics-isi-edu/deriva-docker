

www_install()
{
    require cd /home/$DEVUSER/${STATIC_SITE_NAME}
    require su -c "cp /var/www/html/chaise/lib/navbar/navbar-dependencies.html /home/${DEVUSER}/${STATIC_SITE_NAME}/www/_includes/." ${DEVUSER}
    require su -c "cd ${STATIC_SITE_NAME}/www && jekyll build" - ${DEVUSER}
    require su -c "rsync -a --exclude=chaise/chaise-config.js /home/${DEVUSER}/${STATIC_SITE_NAME}/www/_site/.  /var/www/html/."
}

isrd_prepare_repos()
{
    git_clone_idempotent webauthn.git
    git_clone_idempotent ermrest.git
    git_clone_idempotent hatrac.git
    git_clone_idempotent ermresolve.git
    git_clone_idempotent deriva-py.git
    git_clone_idempotent deriva-web.git
    git_clone_idempotent chaise.git
    git_clone_idempotent ermrestjs.git

    if [[ $STATIC_SITE_NAME ]]; then
      # use this version for public repo
      git_clone_idempotent ${STATIC_SITE_NAME}.git
      # or this version for private repo with SSH
      #git_clone_idempotent git@github.com:informatics-isi-edu/${STATIC_SITE_NAME}.git
    fi
}

isrd_install_code()
{
    isrddev_repo_run webauthn   make install
    isrddev_repo_run ermrest    pip3 install .
    isrddev_repo_run hatrac     pip3 install .
    isrddev_repo_run ermresolve pip3 install .
    isrddev_repo_run deriva-py  pip3 install .
    isrddev_repo_run deriva-web make install
    isrddev_repo_run ermrestjs  make root-install
    isrddev_repo_run chaise     make root-install

    if [[ $STATIC_SITE_NAME ]]; then
      www_install
    fi

    # fixup se-linux context problems seen on some fedora 34 VMs...
    restorecon -rv ${ISRD_PYLIBDIR}
}

isrd_deploy_services()
{
    require id webauthn
    require id ermrest
    require id hatrac
    require id ermresolve

    require [ -r /home/ermrest/ermrest_config.json ]
    require [ -r /home/hatrac/hatrac_config.json ]
    require [ -r /home/ermresolve/ermresolve_config.json ]

    isrddev_repo_run webauthn   make deploy
    if grep -q "Ubuntu" /etc/os-release; then
        isrddev_repo_run ermrest make deploy PLATFORM=ubuntu1604
    else
        isrddev_repo_run ermrest make deploy
    fi
    isrddev_repo_run ermresolve make deploy
    isrddev_repo_run deriva-web make deploy

    if pgdbid hatrac
    then
      isrddev_repo_run hatrac make deploy
    else
      isrddev_repo_run hatrac make deploy-full
    fi

    restorecon -rv /home/webauthn
    restorecon -rv /home/ermrest
    restorecon -rv /home/ermresolve
    restorecon -rv /home/hatrac
}


