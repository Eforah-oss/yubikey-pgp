# yubikey-pgp

Easily use your Yubikey with `git` and `ssh` without manual configuration:
yubikey-pgp is a wrapper for OpenPGP operations with your YubiKey without
having to deal with gpg.

### Installation

If you put your binaries in `~/.local/bin`:

    PREFIX="$HOME/.local" make install

### Usage

There are three main operations you might want to do with your YubiKey. First
the least important: `ykpgp reset` resets all OpenPGP data on your YubiKey, but
does not touch the other functions on it.

Then there's `init` and `register`. `init` is for when your YubiKey is new, and
you want to make sure it is initialized with keys. The purpose of `register` is
setting up your system to use keys that are already on your YubiKey. Setting up
your system is also done by init, so you don't need to run `ykpgp register`
after `ykpgp init`.

These two subcommands have a few options in common:

- `-n` Use temporary GNUPGHOME. Mostly for testing
- `-i <uid>` Add uid (e.g., `name <mail@example.com`) to key. Can be specified
  multiple times. First is primary. If none are given, default is
  "$NAME <$EMAIL>"
- `-g` Set up open git repository for commit signing
- `-G` Set up git for commit signing
- `-s` Add key to possible ssh identities, and set up your shell profile so ssh
  uses gpg.

### On initializing your YubiKey with `-k`

`init` also has the option (for more advanced users) to use keys from the GPG
keyring using `-k`. You could use this to add the same key to multiple
YubiKeys. If no key with (the first of) the given user ID exists, `ykgpg` will
create it for you.

This means these can be used interchangably for GPG operations in principle.
This sounds good, but has some caveats in practice:

- GPG will probably ask for a specific YubiKey ("Please insert the card with
  serial number..."). `ykpgp` can then associate the other key with the
  register flow, but this is a manual step you'll probably need to do every
  time you switch. I have to admit I have not tested this scenario.
- You don't use the safety benefit of generating the key on the YubiKey. Not to
  explain something which might be obvious, but the point of a YubiKey is that
  it's close to impossible to extract the private key. If you generate it on
  the YubiKey itself, it could never have been compromised, as it has never
  even been on the host you're generating it on.
- GPG does not really have the concept of copying a key to a YubiKey. It tries
  to _move_ it (i.e. remove it from the keyring in your `$GNUPGHOME` after
  copying) . Combined with the previous point, this could mean your actual
  private key is forever 'locked up' in that specific YubiKey. If you go this
  route, make sure you have backups (**BEFORE** using `init` if using an
  existing key). `ykpgp` leaves the key data in place (by restoring a backup it
  makes), but even a simple `gpg --card-status` will remove it. So if you want
  to have the same key data on multiple YubiKeys, immediately remove the
  YubiKey after initializing and initialize the next one. And leave your backup
  in place, because there will be a time when GPG will remove the private key
  from your keyring.

In short, while `ykpgp` supports it, I wouldn't recommend doing this with
existing keys unless you're comfortable with handling keys using the GPG
interface. Generating a key, adding it to multiple YubiKeys and then backing it
up is what I would recommend if you're just starting out and don't want to deal
with multiple public keys for yourself.
