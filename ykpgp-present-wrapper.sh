#!/usr/bin/env sh
set -eux

escape() { printf %s\\n "$1" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/' \\\\/"; }
fnmatch() { case "$2" in $1) return 0 ;; *) return 1 ;; esac }

args=''
while
    if fnmatch '--*' "$1"; then
        args="$args$(escape "$1")$(printf \\n\ )"
        shift
    elif getopts ':u:' OPT "$@"; then
        case "$OPT" in
        u)
            args="$args-u $(gpg --with-colons --card-status --fingerprint | awk -F: '/^fpr:/ { print $2 }') "
            ;;
        \?) args="$args-$OPTARG " ;;
        esac
    else
        shift "$((($OPTIND - 1) > 0 ? ($OPTIND - 1) : 1))"
        for x; do
            args="$args$(escape "$x")$(printf \\n\ )"
        done
        args="$args "
        [ "$#" -gt 0 ]
    fi
do
    true
done
eval "set -- $args"
exec gpg "$@"
