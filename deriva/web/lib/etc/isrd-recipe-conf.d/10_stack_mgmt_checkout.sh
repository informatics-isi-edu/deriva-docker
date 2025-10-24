
isrd_checkout_code()
{
    git_checkout webauthn          origin/master
    git_checkout credenza          origin/main
    git_checkout ermrest           origin/master
    git_checkout hatrac            origin/S3-signature-version-fix
    git_checkout ermresolve        origin/master
    git_checkout deriva-web        origin/package-namespace-refactor
    git_checkout deriva-py         origin/master

    git_checkout ermrestjs         origin/master
    git_checkout chaise            origin/master

    if [[ $STATIC_SITE_NAME ]]; then
      git_checkout ${STATIC_SITE_NAME}    origin/main
    fi
}
