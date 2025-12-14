#!/usr/bin/env sh
set -eu

escape() { printf %s\\n "$1" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/'/"; }
fnmatch() { case "$2" in $1) return 0 ;; *) return 1 ;; esac }

map_key() {
    ! fnmatch "*!" "$1" || { printf %s "$1" && return; }
    set -- "$1" "$(gpg --with-colons --card-status --fingerprint \
        | awk -F: '$1 == "fpr" && $2 != "" { print $2 }')"
    gpg --with-colons --with-fingerprint --with-fingerprint \
        --list-keys -- "$1" 2>/dev/null \
        | env query="$1" awk -F: -v card="$2" '
            $1 == "fpr" && $10 == card { found = 1 }
            END { print found ? (card "!") : ENVIRON["query"] }
        '
}

OPTIND=1
args=''
while [ "$#" -gt 0 ]; do
    if [ "$OPTIND" = 1 ] && fnmatch '--?*' "$1"; then
        args="${args+$args }$(escape "$1")"
        shift
    elif [ "$1" != -- ] && getopts ':u:' OPT "$@"; then
        case "$OPT" in
        u)
            args="${args+$args }-u $(escape "$(map_key "$OPTARG")") "
            ;;
        \?) args="${args+$args }-$(escape "$OPTARG")" ;;
        esac
    else
        shift "$((OPTIND - 1))" && OPTIND=1
        for x; do
            args="${args+$args }$(escape "$x")"
        done
        set --
    fi
done
eval "set -- $args"
exec gpg "$@"
