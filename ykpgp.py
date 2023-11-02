import os
import subprocess
import sys
import tempfile
import atexit
import urllib.parse
import shutil
import platform

def run_command(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)

def run_command(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode != 0:
        print(f"ERROR: Command {' '.join(args)} failed with exit code {result.returncode}")
        print(result.stderr)
        exit(result.returncode)
    return result.stdout
def die(message):
    sys.stderr.write(f"{message}\n")
    sys.exit(1)

def confirm(prompt):
    reply = input(f"{prompt} [y/N] ")
    return reply.lower() == 'y'

def gpg_connect_agent(command):
    return run_command('gpg-connect-agent', command, '/bye')

def is_wsl():
    return platform.system().lower() == 'windows' or 'microsoft' in open('/proc/version', 'r', encoding='utf-8').read().lower()

def run_exe_command(cmd, *args, **kwargs):
    #output a message first
    print(f"Running {cmd} {' '.join(args)}")
    return subprocess.Popen([f'{cmd}.exe', *args], **kwargs)

def ykpgp_gpg_commands(fingerprint_or_card_edit, *commands):
    command_input = '\n'.join(commands) + '\n'
    args = ['--command-fd=0', '--status-fd=1', '--expert']
    if fingerprint_or_card_edit == '--card-edit':
        args.append(fingerprint_or_card_edit)
    else:
        args.extend(['--key-edit', fingerprint_or_card_edit])
    
    if is_wsl():
        process = run_exe_command('gpg', *args, text=True, stdin=subprocess.PIPE, stdout=sys.stdout, stderr=sys.stderr)
    else:
        process = subprocess.Popen(['gpg', *args], text=True, stdin=subprocess.PIPE, stdout=sys.stdout, stderr=sys.stderr)
    
    # Send the command_input to the process's stdin
    process.communicate(input=command_input)
    
    if process.returncode != 0:
        print(f"ERROR: Command {' '.join(process.args)} failed with exit code {process.returncode}")
        exit(process.returncode)

def ykpgp_ensure_wsl_gpg():
    if not is_wsl():
        return
    for cmd in ['gpg', 'gpgconf', 'gpg-connect-agent', 'git']:
        if not shutil.which(f"{cmd}.exe"):
            die(f"ERROR: missing {cmd}. Run `make deps` / `choco install gnupg`")

def ykpgp_ensure_pinentry():
    global GPG_TTY
    GPG_TTY = os.environ.get('GPG_TTY', os.ttyname(0))
    if sys.platform == 'darwin' and 'pinentry-program' not in run_command('gpgconf', '-X').stdout \
            and shutil.which('pinentry-mac'):
        temp_file = tempfile.NamedTemporaryFile(delete=False)
        with open(temp_file.name, 'w') as f:
            f.write(f"pinentry-program {shutil.which('pinentry-mac')}\n")
            f.write(open(f"{GNUPGHOME}/gpg-agent.conf").read())
        os.rename(temp_file.name, f"{GNUPGHOME}/gpg-agent.conf")

def ykpgp_pinentry_message(message):
    # URL-encode the message
    url_encoded_message = urllib.parse.quote(message, safe='')
    
    # Replace spaces with %20 and newlines with %0A or %20 depending on the platform
    if 'microsoft' in open('/proc/version').read().lower():
        url_encoded_message = url_encoded_message.replace('%20', '%0A')
    else:
        url_encoded_message = url_encoded_message.replace('%20', ' ')
    
    # Pass the URL-encoded message to gpg-connect-agent
    command = f'get_confirmation {url_encoded_message}'
    result = subprocess.run(['gpg-connect-agent', command, '/bye'], text=True, capture_output=True)
    
    # Check the result for errors and handle them if necessary
    if result.returncode != 0:
        # Handle error (optional)
        pass
    
    return result.stdout

def ykpgp_ensure_name():
    global uids, NAME, EMAIL
    if 'uids' in globals():
        return
    if 'NAME' not in globals():
        NAME = input('Full name? (Consider setting $NAME in your ~/.bashrc): ')
    if 'EMAIL' not in globals():
        EMAIL = input('Email? (Consider setting $EMAIL in your ~/.bashrc): ')
    uids = f"{NAME} <{EMAIL}>"

def ykpgp_use_temp_gnupghome():
    global GNUPGHOME
    GNUPGHOME = tempfile.mkdtemp()
    os.chmod(GNUPGHOME, 0o700)  # Equivalent to chmod og-rwx
    run_command('gpg', '--list-keys')  # Equivalent to gpg --list-keys >/dev/null 2>&1

    def exit_trap():
        run_command('gpg', '--list-keys')
        os.rmdir(GNUPGHOME)  # Equivalent to rm -r "$GNUPGHOME"

    atexit.register(exit_trap)  # Equivalent to trap exit_trap EXIT

def ykpgp_get_gpg_fingerprint(uid):
    output = run_command('gpg', '--with-colons', '--list-secret-keys', uid)
    for line in output.splitlines():
        fields = line.split(':')
        if fields[0] == 'fpr':
            return fields[9]
    print(f"ERROR: Could not find fingerprint for UID {uid}")
    exit(1)

def ykpgp_get_gpg_keyid(fingerprint):
    output = run_command('gpg', '--with-colons', '--list-secret-keys', fingerprint)
    for line in output.splitlines():
        fields = line.split(':')
        if fields[0] == 'sec':
            return fields[4]
    print(f"ERROR: Could not find key ID for fingerprint {fingerprint}")
    exit(1)

def ykpgp_set_algo(S_algo, E_algo, A_algo):
    key_attrs = run_command('gpg', '--card-status').splitlines()
    for line in key_attrs:
        if line.startswith("Key attributes ...:"):
            current_algo = line.split(":")[1].strip()
            if current_algo == f"{S_algo} {E_algo} {A_algo}":
                return  # No need to change key algorithm
    algo_args = []
    for algo in [S_algo, E_algo, A_algo]:
        algo_type, algo_length = (1, algo[3:]) if algo.startswith('rsa') else (2, 1)
        algo_args.extend([str(algo_type), str(algo_length)])
    ykpgp_gpg_commands('--card-edit', 'admin', 'key-attr', *algo_args)

def ykpgp_set_uids(fingerprint):
    global uids
    # Get current primary UID
    output = run_command('gpg', '--with-colons', '--list-secret-keys', fingerprint)
    current_primary_uid = None
    for line in output.splitlines():
        fields = line.split(':')
        if fields[0] == 'uid':
            current_primary_uid = fields[9]
            break
    
    # Split uids string into list of individual uids
    uid_list = uids.split('\n')
    
    # Add uids to key if not already present
    for uid in uid_list:
        uid_exists = any(line.endswith(f':{uid}:') for line in output.splitlines())
        if not uid_exists:
            run_command('gpg', '--quick-add-uid', fingerprint, uid)
    
    # Check if primary uid has changed, and set it back if necessary
    output = run_command('gpg', '--with-colons', '--list-secret-keys', fingerprint)
    new_primary_uid = None
    for line in output.splitlines():
        fields = line.split(':')
        if fields[0] == 'uid':
            new_primary_uid = fields[9]
            break
    if new_primary_uid != current_primary_uid:
        run_command('gpg', '--quick-set-primary-uid', fingerprint, current_primary_uid)

def ykpgp_enable_git(git_config, fingerprint):
    ykpgp_ensure_name()
    run_command('git', 'config', git_config, 'commit.gpgsign', 'true')
    current_user = run_command('git', 'config', 'user.name').strip()
    current_email = run_command('git', 'config', 'user.email').strip()
    current_uid = f'{current_user} <{current_email}>'
    if not any(uid == current_uid for uid in uids.split('\n')):
        key_id = ykpgp_get_gpg_keyid(fingerprint)
        run_command('git', 'config', git_config, 'user.signingkey', key_id)

def ykpgp_enable_ssh(fingerprint):
    gpg_conf_output = run_command('gpgconf', '--list-options', 'gpg-agent')
    if not any(line.split(':')[0] == 'enable-ssh-support' for line in gpg_conf_output.splitlines()):
        run_command('echo', 'enable-ssh-support:1:1', '|', 'gpgconf', '--change-options', 'gpg-agent')

    grip = None
    gpg_output = run_command('gpg', '--with-colons', '--list-secret-keys', fingerprint)
    for line in gpg_output.splitlines():
        fields = line.split(':')
        if fields[0] in ['sub', 'usb'] and 'a' in fields[11]:
            grip = fields[9]
            break

    if grip is None:
        print("ERROR: Couldn't add key to sshcontrol")
        exit(1)
    
    ssh_control_file = os.path.join(run_command('gpgconf', '--list-dirs', 'homedir').strip(), 'sshcontrol')
    with open(ssh_control_file, 'a+') as file:
        content = file.read()
        if grip not in content:
            file.write(f'{grip}\n')
    
    if 'microsoft' in run_command('grep', '-i', 'microsoft', '/proc/version').lower():
        print("WARNING: system-wide ssh setup is not supported on Windows", file=sys.stderr)
        return
    
    shell = os.getenv('SHELL', '/bin/bash').lower()
    ssh_command = 'export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"'
    if 'bash' in shell:
        profile_files = ['.bash_profile', '.bash_login', '.profile', '.bash_profile']
        for profile_file in profile_files:
            profile_path = os.path.join(os.path.expanduser('~'), profile_file)
            if os.path.exists(profile_path):
                with open(profile_path, 'a') as file:
                    file.write(f'{ssh_command}\n')
                break
    elif 'zsh' in shell:
        zprofile_path = os.path.join(os.path.expanduser(os.getenv('ZDOTDIR', '~')), '.zprofile')
        with open(zprofile_path, 'a') as file:
            file.write(f'{ssh_command}\n')
    else:
        print("WARNING: could not add SSH_AUTH_SOCK to your profile", file=sys.stderr)

def ykpgp_register():
    ykpgp_ensure_pinentry()
    ykpgp_ensure_name()

    date_output = run_command('gpg', '--card-status')
    date_match = re.search(r'created\s+:\s+([0-9- :]+)', date_output)
    if date_match is None:
        print("ERROR: Could not find keys on card")
        exit(1)
    
    date_str = date_match.group(1).replace(' ', 'T').replace('-', '').replace(':', '') + '!'
    run_command('gpg', '--faked-system-time', date_str, '--quick-gen-key', uids.split('\n')[0], 'card')
    
    fingerprint = ykpgp_get_gpg_fingerprint(uids.split('\n')[0])
    run_command('gpg', '--quick-set-expire', fingerprint, '0')
    
    run_command('gpg', '--faked-system-time', date_str, '--quick-add-key', fingerprint, 'card', 'auth')
    ykpgp_set_uids(fingerprint)

    if 'git_config' in globals():
        ykpgp_enable_git(globals()['git_config'], fingerprint)
    
    if 'enable_ssh' in globals() and globals()['enable_ssh']:
        ykpgp_enable_ssh(fingerprint)

def ykpgp_init(*args):
    global rsa, stored_keyring_key, git_config, enable_ssh, uids

    rsa = stored_keyring_key = git_config = enable_ssh = uids = None
    options, args = getopt.getopt(args, 'gGi:knrs')

    for opt, arg in options:
        if opt in ('-g',):
            git_config = "--local"
        elif opt in ('-G',):
            git_config = "--global"
        elif opt in ('-i',):
            uids = f"{uids}\n{arg}" if uids else arg
        elif opt in ('-k',):
            stored_keyring_key = True
        elif opt in ('-n',):
            ykpgp_use_temp_gnupghome()
        elif opt in ('-r',):
            rsa = True
        elif opt in ('-s',):
            enable_ssh = True

    ykpgp_ensure_pinentry()
    ykpgp_ensure_name()

    pin_message = (
        'ykpgp will now set up your YubiKey. You will be asked for\n'
        'your (Admin) PIN multiple times. These are the default\n'
        'values:\n'
        '\n'
        '  - PIN: 123456\n'
        '  - Admin PIN: 12345678\n'
        '\n'
        'After generating/copying the keys it will ask you to set\n'
        'up new PINs for this YubiKey. Remember those.'
    )

    passphrase_message = (
        'If you already have a keypair, you will also be asked for\n'
        'its passphrase multiple times. Otherwise, make up\n'
        'something long and safe if you plan on saving the keypair.'
    )

    if run_command('grep', '-iq', 'microsoft', '/proc/version', stderr=None):
        ykpgp_pinentry_message(pin_message)
        if stored_keyring_key:
            ykpgp_pinentry_message(passphrase_message)
    else:
        message = f"{pin_message}\n\n{passphrase_message}" if stored_keyring_key else pin_message
        ykpgp_pinentry_message(message)

    # Attempting to set up kdf, not critical if the card is not reset
    if not ykpgp_gpg_commands('--card-edit', 'admin', 'kdf-setup'):
        pass  # Log or handle the error if necessary

    # Splitting given and surname is imperfect, so only set if unset
    if not run_command('gpg', '--with-colons', '--card-status').decode().count('name:::'):
        us = chr(31)  # ASCII Unit Separator
        split_name = re.sub(
            r' \(([^)]+)\)$',
            lambda match: f"{us}{match.group(1)}",
            uids.split('\n')[0].split(' <')[0]
        )
        ykpgp_gpg_commands('--card-edit', 'admin', 'name', *split_name.split(us))

    if stored_keyring_key:
        # If there's no key in the keyring yet, create it
        if not ykpgp_get_gpg_fingerprint(uids.split('\n')[0]):
            key_type = 'rsa4096' if rsa else 'ed25519'
            run_command('gpg', '--quick-gen-key', uids.split('\n')[0], key_type, 'sign,cert', '0')
        fingerprint = ykpgp_get_gpg_fingerprint(uids.split('\n')[0])

                # Check if encryption subkey exists, if not, add it
        if not re.search(r'^ssb.*[eE]$', run_command('gpg', '--with-colons', '--list-secret-keys', fingerprint).decode(), re.MULTILINE):
            run_command('gpg', '--quick-add-key', fingerprint, 'rsa4096' if rsa else 'cv25519', 'encr', '0')
        
        # Check if authentication subkey exists, if not, add it
        if not re.search(r'^ssb.*[aA]$', run_command('gpg', '--with-colons', '--list-secret-keys', fingerprint).decode(), re.MULTILINE):
            run_command('gpg', '--quick-add-key', fingerprint, 'rsa4096' if rsa else 'ed25519', 'auth', '0')

        ykpgp_set_uids(fingerprint)
        
        # Determine the key algorithms for the card
        algo_info = run_command('gpg', '--with-colons', '--list-keys', fingerprint).decode()
        s_algo = re.search(r'^[ps]ub:.*:[1-9]', algo_info, re.MULTILINE).group()[-1]
        e_algo = re.search(r'^[ps]ub:.*:[2-9]', algo_info, re.MULTILINE).group()[-1]
        a_algo = re.search(r'^[ps]ub:.*:[3-9]', algo_info, re.MULTILINE).group()[-1]
        ykpgp_set_algo(
            'rsa' + s_algo if s_algo == '1' else 'ed25519',
            'rsa' + e_algo if e_algo == '1' else 'cv25519',
            'rsa' + a_algo if a_algo == '1' else 'ed25519'
        )
        
        # Determine which subkey index the [E] and [A] keys have
        key_info = run_command('gpg', '--with-colons', '--list-keys', fingerprint).decode()
        order = (
            str(len(re.findall(r'^sub:.*:[eE]', key_info, re.MULTILINE))),
            str(len(re.findall(r'^sub:.*:[aA]', key_info, re.MULTILINE)))
        )
        
        # Backup private keys, move keys to the card, then restore private keys from backup
        backup = run_command('gpg', '--export-secret-keys', '--armor', fingerprint)
        cardstatus = run_command('gpg', '--with-colons', '--card-status').decode()
        ykpgp_gpg_commands(fingerprint,
                            "key 0", "keytocard", "y", "1",
                            'y' if not re.search(r'^fpr::[^:]*:[^:]*:', cardstatus, re.MULTILINE) else '',
                            "key " + order[0], "keytocard", "2",
                            'y' if not re.search(r'^fpr:[^:]*::[^:]*:', cardstatus, re.MULTILINE) else '',
                            "key 0",
                            "key " + order[1], "keytocard", "3",
                            'y' if not re.search(r'^fpr:[^:]*:[^:]*::', cardstatus, re.MULTILINE) else ''
        )
        ykpgp_gpg_commands('--card-edit', 'admin', 'passwd', '1', '3', 'Q')

        # Delete key stubs to re-add the private keys
        key_grips = re.findall(r'^grp:(.+):', run_command('gpg', '--with-colons', '--list-secret-keys', fingerprint).decode(), re.MULTILINE)
        for key_grip in key_grips:
            gpg_connect_agent(f'delete_key --force {key_grip}')
        
        # Reload keys so gpg does not stay in the 'keys are on card' state
        run_command('gpg', '--import', input=backup)
    else:
        algo = 'rsa4096' if rsa else 'ed25519'
        ykpgp_set_algo(algo, algo, algo)

        replace = 'y' if not run_command('gpg', '--with-colons', '--card-status').decode().count('fpr::::') else ''
        serialno = run_command('gpg', '--with-colons', '--card-status').decode().split('serial:')[1].split(':')[0]

        name_email = uids.split('\n')[0].split(' <')
        name = name_email[0]
        email = name_email[1][:-1]

        ykpgp_gpg_commands('--card-edit', 'admin', 'generate', 'n', replace, '0', 'y', name, email, '')

        fingerprint = ykpgp_get_card_fingerprint(serialno)
        ykpgp_set_uids(fingerprint)

        ykpgp_gpg_commands('--card-edit', 'admin', 'passwd', '1', '3', 'Q')

    if git_config:
        ykpgp_enable_git(git_config, fingerprint)
    if enable_ssh:
        ykpgp_enable_ssh(fingerprint)

def ykpgp_reset():
    confirmation = input("ARE YOU SURE? This is impossible to undo. (y/N): ")
    if confirmation.lower() != 'y':
        return
    ykpgp_gpg_commands("--card-edit", "admin", "factory-reset", "y", "yes")

def ykpgp(command, *args):
    global GNUPGHOME
    GNUPGHOME = os.environ.get('GNUPGHOME', run_command('gpgconf', '--list-dirs', 'homedir').strip())
    ykpgp_ensure_wsl_gpg()
    if command == 'help':
        ykpgp_help()
    elif command == 'register':
        ykpgp_register(*args)
    elif command == 'init':
        ykpgp_init(*args)
    elif command == 'reset':
        ykpgp_reset(*args)
    else:
        ykpgp_help()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        ykpgp('help')
    else:
        ykpgp(sys.argv[1], *sys.argv[2:])
