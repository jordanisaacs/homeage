# homeage - runtime decrypted [age](https://github.com/str4d/rage) secrets for nix home manager

`homeage` is a module for [home-manager](https://github.com/nix-community/home-manager) that enables runtime decryption of declarative age files.

## How it works

On home manager build, the age-encrypted files are built into the nix store and symlinked to the provided `secrets.folder` path. This is achieved through the `home.file` option. Notice that all secret files are encrypted while in the nix store. After the symlinks are finished by home-manager, a decryption script runs. This decryption script is built during the home manager build. To add/remove secrets need to build home manager (hence declarative). The script decrypts the secrets to `/run/user/$UID/secrets/` using the identities provided by `secrets.identityPaths`. When rebooting, the decrypted files are lost as they are in the `/run` folder. Therefore, the decryption script gets called on login using the provided `secrets.startupPath`. To prevent the decryption script from running unnecessarily, a `/run/user/$UID/secrets/lock` file is created on first decryption.


## Options

Check out all the [options](./options.md)

## Roadmap

- [ ] Add symbolic links to decrypted files
- [ ] Add some tests

