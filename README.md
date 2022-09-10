# homeage - runtime decrypted [age](https://github.com/str4d/rage) secrets for nix home manager

`homeage` is a module for [home-manager](https://github.com/nix-community/home-manager) that enables runtime decryption of declarative age files.

## Features

- [x] File agnostic declarative secrets that can be used inside your home-manager flakes
- [X] Symlink (or copy if symlinks aren't supported) decrypted secrets
- [X] Safely cleans up secrets on generation change or systemd service stop
- [x] Encryption is normal age encryption, use your ssh or age keys
- [X] Decryption/cleanup secrets either through systemd services or home-manager activation (for systems without systemd support)

## Management Scheme

Pre-Build:

* Encrypt files with age and make them accessible to home-manager config (through git repository, builtin function, etc.).
* Install your age/ssh key outside of the scope home-manager.

Post-build:

* Encrypted files are copied into the nix store (globally available).
* Scripts for decrypting are are in the nix store (globally available).
    * Because of this **must** to make sure your decryption key has correct file permissions set.

### Systemd Installation

Service Start:
* Decrypts secret and copies/symlinks to locations

Service Stop:
* Cleans up decrypted secret and associated copies/symlinks

Home-manager activation:
* With home-manager systemd reload enabled services will automatically reload/stop during activation for seamless cleanup and re-installation.

### Activation Installation

Home-manager activation:
* Cleans up all secrets that changed between current and previous generation
* Decrypts secret and copies/symlinks to locations

## Getting started

### Non-flake

If you are using homeage without nix flakes feel free to contribute an example config.

### Nix Flakes

Import `homeage.homeManagerModules.homeage` into the configuration and set valid `homeage.identityPaths` and your all set.

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
      
      system = "x86_64-linux";
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

            homeage = {
                # Absolute path to identity (created not through home-manager)
                identityPaths = [ "~/.ssh/id_ed25519" ];

                # "activation" if system doesn't support systemd
                installationType = "systemd";

                file."pijulsecretkey" = {
                  # Path to encrypted file tracked by the git repository
                  source = ./secretkey.json.age;
                  symlinks = [ "${config.xdg.configHome}/pijul/secretkey.json" ];
                  copies = [ "${config.xdg.configHome}/no-symlink-support/secretkey.json" ];
                };
            };

            imports = [ homeage.homeManagerModules.homeage ];
          };
        };
      };
    };
}
```

## Options

See [source](./module/default.nix) for all the options and their descriptions.

## Acknowledgments

The inspiration for this came from RaitoBezarius' [pull request](https://github.com/ryantm/agenix/pull/58/files) to agenix. I have been trying to figure out how to do secrets with home manager for a while and that PR laid out the foundational ideas for how to do it!
