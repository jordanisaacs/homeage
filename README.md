# homeage - runtime decrypted [age](https://github.com/str4d/rage) secrets for nix home manager

`homeage` is a module for [home-manager](https://github.com/nix-community/home-manager) that enables runtime decryption of declarative age files.

## How it works

On home manager build, the age-encrypted files are built into the nix store and symlinked to the provided `homage.folder` path. This is achieved through the home-manager `home.file` option. Notice that all secret files are encrypted while in the nix store. After the symlinks are finished by home-manager, a decryption script runs. This decryption script is built during the home manager build. To add/remove secrets need to build home manager (hence declarative). The script decrypts the secrets to `/run/user/$UID/secrets/` using the identities provided by `homeage.identityPaths`. When rebooting, the decrypted files are lost as they are in the `/run` folder. Therefore, the decryption script gets called on login using the provided `homeage.startupPath`. To prevent the decryption script from running unnecessarily, a `/run/user/$UID/secrets/lock` file is created on first decryption.


## Options

Check out all the [options](./options.md)

## Features

- [x] Declarative secrets that can be used inside your home-manager flakes
- [x] Nothing decrypted stored in the nix store
- [x] File agnostic, uses plain age
- [x] Use ssh or age keys
- [x] Extremely little code, all bash.

## Roadmap

- [ ] Add symbolic links to decrypted files
- [ ] Support passphrases
- [ ] Add tests

