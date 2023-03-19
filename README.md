yubikey-pgp
===========

Easily use your Yubikey with `git` and `ssh` without manual configuration:
yubikey-pgp is a wrapper for OpenPGP operations with your YubiKey without
having to deal with gpg.

### Installation

If you put your binaries in `~/.local/bin`:

    PREFIX="$HOME/.local" make install

### Usage

There are three main operations you might want to do with your
YubiKey. First the least important: `ykpgp reset` resets all OpenPGP
data on your YubiKey, but does not touch the other functions on it.

Then there's `init` and `register`. `init` is for when your YubiKey is
new, and you want to make sure it is initialized with keys. The purpose
of `register` is setting up your system to use keys that are already on
your YubiKey. Setting up your system is also done by init, so you don't
need to run `ykpgp register` after `ykpgp init`.

These two subcommands have a few options in common:

  - `-n`        Use temporary GNUPGHOME. Mostly for testing
  - `-i <uid>`  Add uid (e.g., `name <mail@example.com`) to key.
    Can be specified multiple times. First is primary.
    If none are given, default is "$NAME <$EMAIL>"
  - `-g`        Set up open git repository for commit signing
  - `-G`        Set up git for commit signing
  - `-s`        Add key to possible ssh identities, and set up
    your shell profile so ssh uses gpg.

`init` also has the option (for more advanced users) to use keys from
the GPG keyring using `-k`. This almost invariably results in the actual
key data being removed from the keyring, so if you go this route, make
sure you have backups. `ykpgp` leaves the key data in place, but even
a simple `gpg --card-status` will remove it. So if you want to have the
same key data on multiple YubiKeys, immediately remove the YubiKey after
initializing and initialize the next one.
