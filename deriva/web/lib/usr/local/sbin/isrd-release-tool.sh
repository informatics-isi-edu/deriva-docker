#!/usr/bin/env bash

checkout_script="$1"
reposroot=${2:-../../../}
project="${3:-test}"
rdate="${4:-$(date '+%Y%m%d')}"

############## utility stuff

error()
{
    cat >&2 <<EOF
$0 error: "$@"
usage: $0 scriptpath repospath project YYYYMMDD

This script validates a project script with git_checkout function calls
against product repos expected to be already cloned as siblings
to the division repo containing this script.

This script automatically tags raw commit IDs and outputs a revised
script which uses the tags instead of commit
IDs. When the script already uses tags, they are left unchanged and no
new tag is created.

The new tags are in the form PROJECT-YYYYMMDD.REV using the project
and date arguments from the command-line and the next available REV
starting at 1.

Environment parameters:

  DRY_RUN=true : avoid creating tags or modifying scripts

EOF
    exit 1
}

require()
{
    # usage: require cmd [args...]
    # just run command-line and check for success status code
    "$@" || error Command "($*)" returned non-zero
}

if ! [[ -r "${checkout_script}" ]]
then
    error "Cannot read scriptpath '${checkout_script}'"
fi

if ! [[ -d "${reposroot}" ]]
then
    error "Repos root path '${reposroot}' is not a directory"
fi

# we do fetch ; checkout to be robust against local repo state
get_checkout()
{
    # usage: repodir [ checkout-arg... ]
    require cd "$1"
    require [ -d .git ]
    if [[ "$(stat -c '%U' .git)" != "$(whoami)" ]]
    then
        error Repo "$1" must be owned by the calling user
    fi
    shift
    require git fetch
    require git checkout -f "$@"
}

################ git tasks

repo_action=false

################ main CLI

[ -n "$project" ] || error Project name must not be empty
[[ "$rdate" =~ [0-9]{8} ]] || error Release date must be 8 decimal digits

tmpfile2=$(mktemp /tmp/isrd-releasetool2.sh.XXXXXXX)

cleanup()
{
    rm -f $tmpfile2
}

trap cleanup 0

shopt -s extglob

get_commit()
{
    version="$1"
    [[ -n "$version" ]] || version=origin/master
    line=$(git show "$version" | head -1)
    if [[ $? != 0 ]]
    then
	echo Command "(" git show "$1" ")" did not find a commit
	return 1
    fi

    pattern='^(commit|tag) '
       
    if [[ "$line" =~ $pattern ]]
    then
	git show "$version" | grep '^commit ' | head -1 | sed -e 's/^commit //'
	return 0
    fi
}

is_tag()
{
    line=$(git tag -l "$1")
    [[ "$line" = "$1" ]] && [[ -n "$1" ]]
}

has_tag()
{
    base="${project}-${rdate}."
    line=$(git tag -l --contains "$1" | grep "^${base}[0-9]\+$" | sort -n | tail -1)
    if [[ -n "$line" ]]
    then
	echo "$line"
	return 0
    else
	return 1
    fi
}

repo_check()
{
    repo=$1
    version=$2

    (
	require cd "${reposroot}/$repo"
	require git fetch
	commit=$(get_commit $version)
	echo "$repo $version --> $commit"
    )
}

next_tag()
{
    base="${project}-${rdate}."
    line=$(git tag -l | grep "^${base}[0-9]\+$" | sort -n | tail -1)
    if [[ -n "$line" ]]
    then
	echo "${base}$(( ${line:${#base}} + 1 ))"
    else
	echo "${base}1"
    fi
}

repo_retag()
{
    repo=$1
    shift

    (
	require cd ${reposroot}/$repo
	commit=$(get_commit $1)

	if [[ $? != 0 ]]
	then
	    echo "Could not determine commit ID for $repo from input"
	    return 1
	elif [[ "$1" = "$commit" ]]
	then
	    # input was a raw commit ID
	    next=$(has_tag "$1")
	    if [[ $? = 0 ]]
	    then
		# use existing tag for idempotence
		echo "$repo $commit reuse tag $next"
	    else
		next=$(next_tag)
		echo "$repo $commit create tag $next"
		if [[ "${DRY_RUN:-false}" = true ]]
		then
		    :
		else
		    require git tag -a -m "$project system release $next" "$next" "$commit"
		    require git push origin "$next"
		fi
	    fi
	    printf "    git_checkout %-17s %s\n" "$repo" "$next" >> $tmpfile2
	    return 0
	elif is_tag "$1"
	then
	    # input was a tag
	    echo "$repo $commit reuse tag $1"
	    printf "    git_checkout %-17s %s\n" "$repo" "$1" >> $tmpfile2
	    return 0
	elif [[ -n "$commit" ]]
	then
	    # input can be resolved to a raw commit ID
	    echo "$repo use version $commit without tag"
	    printf "    git_checkout %-17s %s\n" "$repo" "$commit" >> $tmpfile2
	    return 0
	else
	    # input was unexpected
	    echo "Error currently only tags and commit IDs are supported"
	    return 1
	fi
    )
}

git_checkout()
{
    ${repo_action} "$@"
}

scan_with_action()
{
    pattern=' *git_checkout [^ ]+.*'
    while IFS='' read line
    do
        if [[ "$line" =~ $pattern ]]
        then
            eval "$line"
        fi
    done
}

copy_with_action()
{
    pattern=' *git_checkout [^ ]+.*'
    while IFS='' read line
    do
        if [[ "$line" =~ $pattern ]]
        then
            eval "$line"
        else
            printf "%s\n" "$line" >> $tmpfile2
        fi
    done
}

# first pass, make sure all tags or revisions are found
repo_action=repo_check
scan_with_action < ${checkout_script}

# second pass, conditionally retag and build output script
repo_action=repo_retag
copy_with_action < ${checkout_script}

diff "${checkout_script}" $tmpfile2

if [[ "${DRY_RUN:-false}" = true ]]
then
    :
else
    require cp $tmpfile2 ${checkout_script}
    echo "Release cut and ${checkout_script} is updated"
fi

exit 0

