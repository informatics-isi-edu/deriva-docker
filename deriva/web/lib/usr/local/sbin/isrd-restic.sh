#!/bin/bash

# Keep secrets in /home/secrets, other config in /usr/local/etc.

for config in /home/secrets/restic/isrd-restic.conf /etc/isrd-restic.conf $HOME/isrd-restic.conf; do
    if [ -r "$config" ]; then
        . $config
    fi
done

invokedas=$(basename "$0")

# check for zero-arg special invocation names
# to support arg-less runs via cron.daily etc symlinks
if [[ $# -eq 0 ]] && [[ "$invokedas" = "isrd-restic-backup.sh" ]]
then
    restic backup "${backup_flags[@]}" "${backup_dirs[@]}"
elif [[ $# -eq 0 ]] && [[ "$invokedas" = "isrd-restic-forget.sh" ]]
then
    restic forget "${forget_flags[@]}"
elif [[ $# -eq 0 ]] && [[ "$invokedas" = "isrd-restic-prune.sh" ]]
then
    restic prune "${prune_flags[@]}"
elif [[ $# -eq 0 ]] && [[ "$invokedas" = "isrd-restic-check.sh" ]]
then
    if [[ -n "${check_subset_date_fmt}" && -n "${check_subset_modulus}" ]]
    then
        # compute a --read-subset=k/N flag
        # where N is modulus
        # and k is derived from an integer output of $(date +fmt)
        date_number=$(date "+${check_subset_date_fmt}")
        shopt -s extglob # so we can use *(...) pattern
        date_number=${date_number##*(0)} # strip leading zeros
        subset_number=$(( ${date_number} % ${check_subset_modulus} ))
        check_flags+=( "--read-data-subset=${subset_number}/${check_subset_modulus}" )
    fi
    restic check "${check_flags[@]}"
else
    # otherwise pass args as simple wrapper for admin/CLI usage
    restic "$@"
fi
