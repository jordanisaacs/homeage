# homeage - runtime decrypted [age](https://github.com/str4d/rage) secrets for nix home manager

`homeage` is a module for [home-manager](https://github.com/nix-community/home-manager) that enables runtime decryption of declarative age files.

## Features

- [x] Declarative secrets that can be used inside your home-manager flakes
- [x] Nothing decrypted stored in the nix store
- [x] File agnostic, uses plain age
- [x] Use ssh or age keys
- [x] Extremely little code, all bash.
- [X] Add symbolic links to decrypted files

## Roadmap

- [ ] Support passphrases
- [ ] Add tests

## Getting started

### Nix Flakes

While the following below is immense, its mostly just home manager flake boilerplate. All you need to do is import `homeage.homeManagerModules.homeage` into the configuration and set a valid `homeage.identityPaths` and your all set.

```
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
  }

  outputs = { nixpkgs, homeage, ... }@inputs:
    let
      pkgs = import nixpkgs {
        inherit system;
      };
      
      system = "x86-64_linux";
      username = "jd";
      stateVersion = "21.05";
    in {
      home-manager.lib.homeManagerConfiguration {
        inherit system stateVersion username pkgs;
        home.homeDirectory = "/home/${username}";

        configuration = {
          home.stateVersion = stateVersion;
          home.username = username;
          home.homeDirectory = "/home/${username}";

          # CHECK HERE for homeage configuration
          homeage.identityPaths = [ "~/.ssh/id_ed25519" ];
          homeage.file."pijul/secretkey.json" = {
            source = ./secretkey.json.age;
            symlinks = [ "${config.xdg.configHome}/pijul/secretkey.json" ];
          };

          imports = [ homeage.homeManagerModules.homeage ];
        };
      };
    }
}
```

## Options

Check out all the [options](./options.md)

## How it works

On home manager build, the age-encrypted files are built into the nix store and symlinked to the provided `homage.folder` path. This is achieved through the home-manager `home.file` option. Notice that all secret files are encrypted while in the nix store. After the symlinks are finished by home-manager, a decryption script runs. This decryption script is built during the home manager build. To add/remove secrets need to build home manager (hence declarative). The script decrypts the secrets to `/run/user/$UID/secrets/` using the identities provided by `homeage.identityPaths`. It then acts on the decrypted file (changing ownership, linking, etc.). When rebooting, the decrypted files are lost as they are in the `/run` folder. Therefore, the decryption script gets called on login using the provided `homeage.startupPath`. To prevent the decryption script from running unnecessarily, a `/run/user/$UID/secrets/lock` file is created on first decryption.


## Acknowledgments

The inspiration for this came from RaitoBezarius' [pull request](https://github.com/ryantm/agenix/pull/58/files) to agenix. I have been trying to figure out how to do secrets with home manager for a while and that PR laid out the foundational ideas for how to do it!
