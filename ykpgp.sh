#!/usr/bin/env sh
set -eu

die() { printf '%s\n' "$*" >&2; exit 1; }

confirm() ( #1: prompt
    printf "%s [y/N] " "$1"
    read -r REPLY
    [ "$REPLY" = y ]
)

ykpgp_ensure_name() {
    if [ -z "${NAME-}" ]; then
        printf 'Full name? (Consider setting $NAME in your ~/.bashrc): '
        read -r NAME
    fi
    if [ -z "${EMAIL-}" ]; then
        printf 'Email? (Consider setting $EMAIL in your ~/.bashrc): '
        read -r EMAIL
    fi
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

ykpgp_help() {
    printf '%s\n' \
        'Usage: ykpgp [options...] <command>' \
        '' \
        'Manage YubiKey OpenPGP keys using gpg' \
        '' \
        'Options:' \
        '  -n        Use temporary GNUPGHOME. Mostly for testing' \
        '' \
        'Commands:' \
        '  register  Import keys from YubiKey for use with gpg' \
        '  init      Initialise the YubiKey' \
        '    -r      Create RSA keys instead of ECC' \
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
    gpg --faked-system-time "$date" --quick-gen-key "$NAME <$EMAIL>" card
    fingerprint="$(gpg --fingerprint | sed -n '/^\s/{s/\s\s*//g;p;q}')"
    #Adds the [A] (auth) subkey
    gpg --faked-system-time "$date" --quick-add-key "$fingerprint" card auth
}

ykpgp_init() {
    unset rsa
    while getopts 'nr' OPT "$@"; do
        case "$OPT" in
            n) ykpgp_use_temp_gnupghome ;;
            r) rsa=true ;;
        esac
    done
    shift $(( $OPTIND - 1 ))
    ykpgp_ensure_name
    #Splitting given and surname is imperfect, so only set if unset
    if [ "$(gpg --card-status \
            | sed -n 's/Name of cardholder: //p')" = "[not set]" ]; then
        us="$(printf '\037')"; #ASCII Unit Separator
        split_name="$(echo "$NAME" \
            | sed 's/ \(\([^[:upper:]]* \)*[[:upper:]][^ ]*\)$/'"$us"'\1/')"
        ykpgp_gpg_commands --card-edit \
            admin name "${split_name#*$us}" "${split_name%$us*}"
    fi
    ykpgp_set_algo \
        "$("${rsa-false}" && echo rsa4096 || echo ed25519)" \
        "$("${rsa-false}" && echo rsa4096 || echo cv25519)" \
        "$("${rsa-false}" && echo rsa4096 || echo ed25519)"
    replace="$(gpg --card-status | sed -n '/^\s*created ....:/{a\y
        }')"
    ykpgp_gpg_commands --card-edit \
        admin generate n $replace 0 y "$NAME" "$EMAIL" ""
}

ykpgp_reset() {
    confirm "ARE YOU SURE? This is impossible to undo." || return
    ykpgp_gpg_commands --card-edit admin factory-reset y yes
}

ykpgp() {
    [ "$1" != --help ] || set -- help
    while getopts 'hn' OPT "$@"; do
        case "$OPT" in
            h) set -- help ;;
            n) ykpgp_use_temp_gnupghome ;;
        esac
    done
    shift $(( $OPTIND - 1 ))
    case "$1" in
        help) shift 1; ykpgp_help ;;
        register) shift 1; ykpgp_register "$@" ;;
        init) shift 1; ykpgp_init "$@" ;;
        reset) shift 1; ykpgp_reset "$@" ;;
    esac
}

ykpgp "$@"
