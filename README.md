# homeage - runtime decrypted [age](https://github.com/str4d/rage) secrets for nix home manager

`homeage` is a module for [home-manager](https://github.com/nix-community/home-manager) that enables runtime decryption of declarative age files.

## Features

- [x] File agnostic declarative secrets that can be used inside your home-manager flakes
- [x] Each secret gets decrypted with its own systemd service integrating seamlessly with home-manager reload and update
- [x] Just normal age encryption, use ssh or age keys
- [X] Add symbolic links to decrypted files
- [x] Extremely little bash script so inspect the source yourself!

## Management Scheme

**Pre-Build**: Files are encrypted by external age key in repository (unencrypted with associated public key on roadmap)

**Post-Build**: Files are encrypted by external age key while in nix store

**Runtime**: Files are stored unencrypted in `/run/user/$UID/secrets` and can be symlinked to other locations

**Safety Checks**:

- On activation, ensures there are no conflicts with other declared paths (including `home.file` paths)

Notes (in progress [fixes](https://github.com/jordanisaacs/homeage/issues/8#issue-1047731755)):

1. Currently all `home.file.<name>.symlinks` are not cleaned up on new home-manager generation. Therefore a symlink that points to a decrypted yaml file named `hello` in one generation, instead of being deleted will point to a png file named `hello` in the next.

2. Currently the `/run` secrets folder is not cleaned on home-manager activation. Therefore old secrets will exist decrypted until reboot.

## Roadmap

- [ ] Implement cleanup
- [ ] Support passphrases
- [ ] Support unencrypted with public key files
- [ ] Add checks

## Getting started

### Nix Flakes

While the following below is immense, its mostly just home manager flake boilerplate. All you need to do is import `homeage.homeManagerModules.homeage` into the configuration and set a valid `homeage.identityPaths` and your all set.

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    homeage = {
      url = "github:jordanisaacs/homeage";
      # Optional
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, homeage, ... }@inputs:
    let
      pkgs = import nixpkgs {
        inherit system;
      };
      
      system = "x86-64_linux";
      username = "jd";
      stateVersion = "21.05";
    in {
      homeManagerConfigurations = {
        jd = home-manager.lib.homeManagerConfiguration {
          inherit system stateVersion username pkgs;
          home.homeDirectory = "/home/${username}";

          configuration = {
            home.stateVersion = stateVersion;
            home.username = username;
            home.homeDirectory = "/home/${username}";

            # CHECK HERE for homeage configuration
            homeage.identityPaths = [ "~/.ssh/id_ed25519" ];
            homeage.file."pijulsecretkey" = {
              source = ./secretkey.json.age;
              path = "pijul/secretkey.json";
              symlinks = [ "${config.xdg.configHome}/pijul/secretkey.json" ];
            };

            imports = [ homeage.homeManagerModules.homeage ];
          };
        };
      };
    };
}
```

## Options

Check out all the [options](./options.md)

## How it works

On home manager build, the age-encrypted files are built into the nix store and symlinked to the provided `homeage.folder` path. This is achieved through the home-manager `home.file` option. Notice that all secret files are encrypted while in the nix store. After the symlinks are finished by home-manager, the systemd units are run. Each secret has its own `oneshot` service that runs a decryption script. This works seamlessly with home-managers updating/reloading of systemd units. The script decrypts the secrets to `/run/user/$UID/secrets/` using the identities provided by `homeage.identityPaths`. It then acts on the decrypted file (changing ownership, linking, etc.). When rebooting, the decrypted files are lost as they are in the `/run` folder. Therefore, the systemd unit is wanted by `default.target` so it will run on startup.

## Acknowledgments

The inspiration for this came from RaitoBezarius' [pull request](https://github.com/ryantm/agenix/pull/58/files) to agenix. I have been trying to figure out how to do secrets with home manager for a while and that PR laid out the foundational ideas for how to do it!
