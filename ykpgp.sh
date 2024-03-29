#!/usr/bin/env sh
set -eu

die() { printf '%s\n' "$*" >&2; exit 1; }

confirm() ( #1: prompt
    printf "%s [y/N] " "$1"
    read -r REPLY
    [ "$REPLY" = y ]
)

gpg_connect_agent() { gpg-connect-agent "$@"; }

ykpgp_ensure_wsl_gpg() {
    grep -iq microsoft /proc/version 2>/dev/null || return 0
    #For the case when it's just installed
    if ! command -v gpg.exe >/dev/null 2>&1; then
        printf "ERROR: missing gpg. Run `make deps` / `choco install gnupg`">&2
        die "If you installed it this boot, restart your computer."
    fi
    gpg() { gpg.exe "$@"; }
    gpgconf() { gpgconf.exe "$@"; }
    gpg_connect_agent() { gpg-connect-agent.exe "$@"; }
    git() { git.exe "$@"; }
}

ykpgp_ensure_pinentry() {
    export GPG_TTY="${GPG_TTY-$(tty)}"
    if [ "$(uname -s)" = Darwin ] \
            && ! gpgconf -X | grep -q pinentry-program \
            && command -v pinentry-mac >/dev/null 2>&1; then
        #For some reason gpgconf does not do pinentry-program, both r/w
        set -- "$(mktemp)"
        {
            printf 'pinentry-program %s\n' "$(command -v pinentry-mac)"
            cat "$GNUPGHOME/gpg-agent.conf" 2>/dev/null ||:
        } >"$1" && cp "$1" "$GNUPGHOME/gpg-agent.conf" && rm "$1"
    fi
}

ykpgp_pinentry_message() {
    gpg_connect_agent "get_confirmation $(echo "$@" | {
        if grep -iq microsoft /proc/version 2>/dev/null; then
            sed 's/$/%20/;s/ /%20/g' | tr -d \\n
        else
            sed 's/$/%0A/;s/ /%20/g' | tr -d \\n
        fi
    })" /bye
}

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

ykpgp_get_gpg_keyid() { #1: fingerprint
    set -- "$(gpg --with-colons --list-secret-keys "$1" \
        | awk -F: '/^sec/ { print $5; exit; }')"
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

ykpgp_enable_git() { #1: git_config 2: fingerprint
    ykpgp_ensure_name
    git config "$1" commit.gpgsign true
    if ! echo "$uids" | grep -qxF \
            "$(git config user.name) <$(git config user.email)>"; then
        git config "$1" user.signingkey "$(ykpgp_get_gpg_keyid "$2")"
    fi
}

ykpgp_enable_ssh() { #1: fingerprint
    gpgconf --list-options gpg-agent \
        | awk -F: '/^enable-ssh-support/ { exit ! $10 }' \
        || echo 'enable-ssh-support:1:1' | gpgconf --change-options gpg-agent \
        >/dev/null
    grip="$(gpg --with-colons --list-secret-keys "$1" | awk -F: '
        $1 ~ /s[us]b/ && $12 ~ /a/ { auth = 1 }
        $1 == "grp" && auth == 1 { print $10; exit }
    ')"
    [ -n "$grip" ] || die "Couldn't add key to sshcontrol"
    grep -qxF "$grip" "$(gpgconf --list-dirs homedir)/sshcontrol" 2>/dev/null \
        || echo "$grip" >>"$(gpgconf --list-dirs homedir)/sshcontrol"
    if grep -iq microsoft /proc/version 2>/dev/null; then
        echo "WARNING: system-wide ssh setup is not supported on Windows" >&2
        return 0
    fi
    #Check whether it is already added by reloading profile. Might be run twice
    ! expr "$("$SHELL" -lic "printenv SSH_AUTH_SOCK")" : '.*gpg-agent' \
        >/dev/null || return 0
    case "$SHELL" in
    */bash)
        #Match bash in finding file, first is also last as default to write to
        for profile in .bash_profile .bash_login .profile .bash_profile; do
            ! [ -r "$HOME/$profile" ] || break
        done
        echo 'export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"' \
            >>"$HOME/$profile"
        ;;
    */zsh)
        echo 'export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"' \
            >>"$("$SHELL" -lc 'printf "%s" "${ZDOTDIR-$HOME}"')/.zprofile"
        ;;
    *) echo "WARNING: could not add SSH_AUTH_SOCK to your profile" >&2 ;;
    esac
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
        '  -g        Set up open git repository for commit signing' \
        '  -G        Set up git for commit signing' \
        '  -s        Add key to possible ssh identities, and set up' \
        '            your shell profile so ssh uses gpg.' \
        '' \
        'Commands:' \
        '  register  Import keys from YubiKey for use with gpg' \
        '  init      Initialise the YubiKey' \
        '    -r      Create RSA keys instead of ECC' \
        '    -k      Use stored keypair' \
        '  reset     Clear (factory-reset) all OpenPGP data on YubiKey'
}

ykpgp_register() {
    ykpgp_ensure_pinentry
    ykpgp_ensure_name
    #First running gpg --card-status accomplishes 2 goals. First, it keeps the
    #id of the key the same by reusing the creation time. It also avoids a
    #`Key generation failed: No such file or directory` error when trying to
    #add the key.
    date="$(gpg --card-status | sed -n '/^ *created ....: /{
        s/.*\([-0-9 :]\{19\}\)$/\1/;s/ /T/;s/$/!/;s/[-:]//g;p;q;}')"
    [ -n "$date" ] || die "Could not find keys on card"
    #Adds the [SC] (meaning sign and certify) key and [E] (encryption) subkey
    gpg --faked-system-time "$date" --quick-gen-key \
        "$(echo "$uids" | head -n 1)" card
    fingerprint="$(ykpgp_get_gpg_fingerprint "$(echo "$uids" | head -n1)")"
    gpg --quick-set-expire "$fingerprint" 0
    #Adds the [A] (auth) subkey
    gpg --faked-system-time "$date" --quick-add-key "$fingerprint" card auth
    ykpgp_set_uids "$fingerprint"
    [ -z "${git_config-}" ] || ykpgp_enable_git "$git_config" "$fingerprint"
    ! "${enable_ssh-false}" || ykpgp_enable_ssh "$fingerprint"
}

ykpgp_init() {
    unset rsa
    while getopts 'gGi:knrs' OPT "$@"; do
        case "$OPT" in
            g) git_config="--local" ;;
            G) git_config="--global" ;;
            i) uids="${uids-}$(printf "${uids+\\n}%s" "$OPTARG")" ;;
            k) stored_keyring_key=true ;;
            n) ykpgp_use_temp_gnupghome ;;
            r) rsa=true ;;
            s) enable_ssh=true ;;
        esac
    done
    shift $(( $OPTIND - 1 )); OPTIND=1
    ykpgp_ensure_pinentry
    ykpgp_ensure_name
    pin_message="$(printf '%s\n' \
        'ykpgp will now set up your YubiKey. You will be asked for' \
        'your (Admin) PIN multiple times. These are the default' \
        'values:' \
        '' \
        '  - PIN: 123456' \
        '  - Admin PIN: 12345678' \
        '' \
        'After generating/copying the keys it will ask you to set' \
        'up new PINs for this YubiKey. Remember those.')"
    passphrase_message="$(printf '%s\n' \
        'If you already have a keypair, you will also be asked for' \
        'its passphrase multiple times. Otherwise, make up' \
        'something long and safe if you plan on saving the keypair.'
    )"
    if grep -iq microsoft /proc/version 2>/dev/null; then
        ykpgp_pinentry_message "$pin_message"
        ! "${stored_keyring_key-false}" \
            || ykpgp_pinentry_message "$passphrase_message"
    else
        ykpgp_pinentry_message "$(echo "$pin_message" \
            && "${stored_keyring_key-false}" \
            && echo && echo "$passphrase_message" ||:)"
    fi
    #Try setting up kdf. Not worth bothering the user over if card is not reset
    ykpgp_gpg_commands --card-edit admin kdf-setup ||:
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
        ykpgp_gpg_commands --card-edit admin passwd 1 3 Q
        #Delete key stubs to re add the private keys
        gpg --with-colons --list-secret-keys "$fingerprint" \
            | awk -F: '/^grp:/ { print $10 }' \
            | while read -r keygrip; do
                gpg_connect_agent "delete_key --force $keygrip" /bye
            done
        #Reload keys so gpg does not stay in the 'keys are on card' state
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
        fingerprint="$(ykpgp_get_card_fingerprint "$serialno")"
        ykpgp_set_uids "$fingerprint"
        ykpgp_gpg_commands --card-edit admin passwd 1 3 Q
    fi
    [ -z "${git_config-}" ] || ykpgp_enable_git "$git_config" "$fingerprint"
    ! "${enable_ssh-false}" || ykpgp_enable_ssh "$fingerprint"
}

ykpgp_reset() {
    confirm "ARE YOU SURE? This is impossible to undo." || return
    ykpgp_gpg_commands --card-edit admin factory-reset y yes
}

ykpgp() {
    [ "$#" -gt 0 ] || set -- help
    [ "$1" != --help ] || set -- help
    unset git_config enable_ssh uids
    export GNUPGHOME="${GNUPGHOME-$(gpgconf --list-dirs homedir)}"
    while getopts 'gGhi:ns' OPT "$@"; do
        case "$OPT" in
            g) git_config="--local" ;;
            G) git_config="--global" ;;
            h) set -- help; OPTIND=1 ;;
            i) uids="${uids-}$(printf "${uids+\\n}%s" "$OPTARG")" ;;
            n) ykpgp_use_temp_gnupghome ;;
            s) enable_ssh=true ;;
        esac
    done
    shift $(( $OPTIND - 1 )); OPTIND=1
    mkdir -p "$GNUPGHOME"
    chmod og-rwx "$GNUPGHOME"
    ykpgp_ensure_wsl_gpg
    case "$1" in
        help) shift 1; ykpgp_help ;;
        register) shift 1; ykpgp_register "$@" ;;
        init) shift 1; ykpgp_init "$@" ;;
        reset) shift 1; ykpgp_reset "$@" ;;
    esac
}

ykpgp "$@"
