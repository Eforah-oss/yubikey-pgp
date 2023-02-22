#!/usr/bin/env sh
set -eu

die() { printf '%s\n' "$*" >&2; exit 1; }

confirm() ( #1: prompt
    printf "%s [y/N] " "$1"
    read -r REPLY
    [ "$REPLY" = y ]
)

ykpgp_ensure_name() {
    [ -z "${uids-}" ] || return 0
    if [ -z "${NAME-}" ]; then
        printf 'Full name? (Consider setting $NAME in your ~/.bashrc): '
        read -r NAME
    fi
    if [ -z "${EMAIL-}" ]; then
        printf 'Email? (Consider setting $EMAIL in your ~/.bashrc): '
        read -r EMAIL
    fi
    uids="$NAME <$EMAIL>"
}

ykpgp_use_temp_gnupghome() {
    export GNUPGHOME="$(mktemp -d)"
    chmod og-rwx "$GNUPGHOME"
    gpg --list-keys >/dev/null 2>&1
    exit_trap() { gpg --list-keys; rm -r "$GNUPGHOME"; }
    trap exit_trap EXIT
}

ykpgp_gpg_commands() { #1: fingerprint or --card-edit
    (shift 1; printf "%s\\n" "$@") \
        | gpg --command-fd=0 --status-fd=1 --expert \
            $([ "$1" = --card-edit ] || echo --key-edit) "$1"
}

ykpgp_get_gpg_fingerprint() { #1: uid
    set -- "$(gpg --with-colons --list-secret-keys "$1" \
        | awk -F: '/^fpr:/ { print $10; exit; }')"
    [ -n "$1" ] || return 1
    echo "$1"
}

ykpgp_get_card_fingerprint() { #1: serialno
    set -- "$(gpg --with-colons --list-secret-keys | awk -F: -vserialno="$1" '
        /^sec:/ { oncard = index($15, serialno) }
        /^fpr:/ { if (oncard) { print $10; exit; } }
    ')"
    [ -n "$1" ] || return 1
    echo "$1"
}

ykpgp_set_algo() { #1: S_algo E_algo A_algo
    #Set key algorithm only if necessary to avoid pin dialogs
    if ! gpg --card-status | grep -qxF "Key attributes ...: $1 $2 $3"; then
        ykpgp_gpg_commands --card-edit \
            admin key-attr \
            $(expr "$1" : rsa && echo 1 "${1#rsa}" || echo 2 1) \
            $(expr "$2" : rsa && echo 1 "${2#rsa}" || echo 2 1) \
            $(expr "$3" : rsa && echo 1 "${3#rsa}" || echo 2 1)
    fi
}

ykpgp_set_uids() { #1: fingerprint
    set -- "$1" "$(gpg --with-colons --list-secret-keys "$1" \
        | awk -F: '/^uid/ { print $10; exit }')"
    echo "$uids" | while read -r uid; do
        gpg --with-colons --list-secret-keys "$1" \
            | grep '^uid' | grep -qF "$uid" \
            || gpg --quick-add-uid "$1" "$uid"
    done
    #If adding uids has changed the primary, set it back to the original value
    gpg --with-colons --list-secret-keys "$1" \
        | awk -F: '/^uid/ { print $10; exit }' \
        | grep -qxF "$2" \
        || gpg --quick-set-primary-uid "$1" "$2"
}

ykpgp_help() {
    printf '%s\n' \
        'Usage: ykpgp [options...] <command>' \
        '' \
        'Manage YubiKey OpenPGP keys using gpg' \
        '' \
        'Options:' \
        '  -n        Use temporary GNUPGHOME. Mostly for testing' \
        '  -i <uid>  Add uid (e.g., `name <mail@example.com`) to key' \
        '            Can be specified multiple times. First is primary' \
        '            If none are given, default is "$NAME <$EMAIL>"' \
        '' \
        'Commands:' \
        '  register  Import keys from YubiKey for use with gpg' \
        '  init      Initialise the YubiKey' \
        '    -r      Create RSA keys instead of ECC' \
        '    -k      Use stored keypair' \
        '  reset     Clear (factory-reset) all OpenPGP data on YubiKey'
}

ykpgp_register() {
    ykpgp_ensure_name
    #First running gpg --card-status accomplishes 2 goals. First, it keeps the
    #id of the key the same by reusing the creation time. It also avoids a
    #`Key generation failed: No such file or directory` error when trying to
    #add the key.
    date="$(gpg --card-status | sed -n '/^\s*created ....: /{
        s/.*\([-0-9 :]\{19\}\)$/\1/;s/ /T/;s/$/!/;s/[-:]//g;p;q}')"
    [ -n "$date" ] || die "Could not find keys on card"
    #Adds the [SC] (meaning sign and certify) key and [E] (encryption) subkey
    gpg --faked-system-time "$date" --quick-gen-key \
        "$(echo "$uids" | head -n 1)" card
    fingerprint="$(ykpgp_get_gpg_fingerprint "$(echo "$uids" | head -n1)")"
    gpg --quick-set-expire "$fingerprint" 0
    #Adds the [A] (auth) subkey
    gpg --faked-system-time "$date" --quick-add-key "$fingerprint" card auth
    ykpgp_set_uids "$fingerprint"
}

ykpgp_init() {
    unset rsa
    while getopts 'i:knr' OPT "$@"; do
        case "$OPT" in
            i) uids="${uids-}$(printf "${uids+\\n}%s" "$OPTARG")" ;;
            k) stored_keyring_key=true ;;
            n) ykpgp_use_temp_gnupghome ;;
            r) rsa=true ;;
        esac
    done
    shift $(( $OPTIND - 1 )); OPTIND=1
    ykpgp_ensure_name
    #Splitting given and surname is imperfect, so only set if unset
    if gpg --with-colons --card-status | grep -qFx name:::; then
        us="$(printf '\037')"; #ASCII Unit Separator
        split_name="$(echo "$uids" | sed '
                1!d
                s/ <[^>]*>$//
                s/ \(\([^[:upper:]]* \)*[[:upper:]][^ ]*\)$/'"$us"'\1/
            ')"
        ykpgp_gpg_commands --card-edit \
            admin name "${split_name#*$us}" "${split_name%$us*}"
    fi
    if "${stored_keyring_key-false}"; then
        #If there is no key in the keyring yet, create it
        ykpgp_get_gpg_fingerprint "$(echo "$uids" | head -n 1)" >/dev/null \
            || gpg --quick-gen-key "$(echo "$uids" | head -n 1)" \
                "$("${rsa-false}" && echo rsa4096 || echo ed25519)" sign,cert 0
        fingerprint="$(ykpgp_get_gpg_fingerprint "$(echo "$uids" | head -n1)")"
        gpg --with-colons --list-secret-keys "$fingerprint" \
            | awk -F: '$1 == "ssb" && $12 == "e" { f = 1 } END { exit !f }' \
            || gpg --quick-add-key "$fingerprint" \
                "$("${rsa-false}" && echo rsa4096 || echo cv25519)" encr 0
        gpg --with-colons --list-secret-keys "$fingerprint" \
            | awk -F: '$1 == "ssb" && $12 == "a" { f = 1 } END { exit !f }' \
            || gpg --quick-add-key "$fingerprint" \
                "$("${rsa-false}" && echo rsa4096 || echo ed25519)" auth 0
        ykpgp_set_uids "$fingerprint"
        #What algorithms should the card be set to?
        ykpgp_set_algo $(gpg --with-colons --list-keys "$fingerprint"|awk -F: '
            /^[ps]ub:/ {
                a[index($12, "sc") ? "s" : $12] = ($4 == 1 ? "rsa" $3 : $17)
            }
            END { print a["s"] " " a["e"] " " a["a"]; }
        ')
        #Which subkey index do the [E] and [A] key have?
        order="$(gpg --with-colons --list-keys "$fingerprint" | awk -F: '
            /^sub:/ { c += 1; a[$12] = c; }
            END { print a["e"] " " a["a"]; }
        ')"
        #'Move' the keys. Make that a copy by backing up the private keys
        backup="$(gpg --export-secret-keys --armor "$fingerprint")"
        cardstatus="$(gpg --with-colons --card-status)"
        ykpgp_gpg_commands "$fingerprint" \
            "key 0" keytocard y 1 \
                $(echo "$cardstatus" | grep -xq 'fpr::[^:]*:[^:]*:' || echo y)\
            "key ${order% *}" keytocard 2 \
                $(echo "$cardstatus" | grep -xq 'fpr:[^:]*::[^:]*:' || echo y)\
            "key 0" \
            "key ${order#* }" keytocard 3 \
                $(echo "$cardstatus" | grep -xq 'fpr:[^:]*:[^:]*::' || echo y)
        #Delete key stubs to re add the private keys
        gpg --with-colons --list-secret-keys "$fingerprint" \
            | awk -F: '/^grp:/ { print $10 }' \
            | while read -r keygrip; do
                gpg-connect-agent "delete_key --force $keygrip" /bye
            done
        #Reload gpg-agent so it does not keep the 'keys are on card' state
        echo "$backup" | gpg --import
    else
        ykpgp_set_algo \
            "$("${rsa-false}" && echo rsa4096 || echo ed25519)" \
            "$("${rsa-false}" && echo rsa4096 || echo cv25519)" \
            "$("${rsa-false}" && echo rsa4096 || echo ed25519)"
        replace="$(gpg --with-colons --card-status \
            | grep -qxF fpr:::: || echo y)"
        serialno="$(gpg --with-colons --card-status \
            | awk -F: '/^serial:/ { print $2 }')"
        ykpgp_gpg_commands --card-edit \
            admin generate n $replace 0 y \
                "$(echo "$uids" | sed '1!d;s/ <[^>]*>$//')" \
                "$(echo "$uids" | sed '1!d;s/.* <\([^>]*\)>$/\1/')" \
                ""
        ykpgp_set_uids "$(ykpgp_get_card_fingerprint "$serialno")"
    fi
}

ykpgp_reset() {
    confirm "ARE YOU SURE? This is impossible to undo." || return
    ykpgp_gpg_commands --card-edit admin factory-reset y yes
}

ykpgp() {
    [ "$#" -gt 0 ] || set -- help
    [ "$1" != --help ] || set -- help
    unset uids
    while getopts 'hi:n' OPT "$@"; do
        case "$OPT" in
            h) set -- help; OPTIND=1 ;;
            i) uids="${uids-}$(printf "${uids+\\n}%s" "$OPTARG")" ;;
            n) ykpgp_use_temp_gnupghome ;;
        esac
    done
    shift $(( $OPTIND - 1 )); OPTIND=1
    mkdir -p "$GNUPGHOME"
    chmod og-rwx "$GNUPGHOME"
    case "$1" in
        help) shift 1; ykpgp_help ;;
        register) shift 1; ykpgp_register "$@" ;;
        init) shift 1; ykpgp_init "$@" ;;
        reset) shift 1; ykpgp_reset "$@" ;;
    esac
}

ykpgp "$@"
