{ pkgs, config, options, lib, ... }:
with lib;

let
  cfg = config.homeage;

  # All files are decrypted to /run/user and cleaned up when rebooted
  runtimeDecryptFolder = cfg.mount;

  ageBin = if cfg.isRage then "${cfg.pkg}/bin/rage" else "${cfg.pkg}/bin/age";

  runtimeDecryptPath = path: runtimeDecryptFolder + "/" + path;

  identities = builtins.concatStringsSep " " (map (path: "-i ${path}") cfg.identityPaths);

  createFiles = command: runtimepath: destinations: builtins.concatStringsSep "\n" ((map (dest: ''
    mkdir -p $(dirname ${dest})
    ${command} ${runtimepath} ${dest}
  '')) destinations);

  decryptSecret = name: { source, path, symlinks, cpOnService, mode, owner, group, ... }:
    let
      runtimepath = runtimeDecryptPath path;
      linksCmds = createFiles "ln -sf" runtimepath symlinks;
      copiesCmds = createFiles "cp -f" runtimepath cpOnService;
    in
    pkgs.writeShellScriptBin "${name}-decrypt" ''
      set -euo pipefail

      echo "Decrypting secret ${source} to ${runtimepath}"
      TMP_FILE="${runtimepath}.tmp"
      mkdir -p $(dirname ${runtimepath})
      (
        umask u=r,g=,o=
        ${ageBin} -d ${identities} -o "$TMP_FILE" "${source}"
      )
      chmod ${mode} "$TMP_FILE"
      chown ${owner}:${group} "$TMP_FILE"
      mv -f "$TMP_FILE" "${runtimepath}"
      ${linksCmds}
      ${copiesCmds}
    '';

  mkServices = lib.attrsets.mapAttrs'
    (name: value:
      lib.attrsets.nameValuePair
        ("${name}-secret")
        ({
          Unit = {
            Description = "Decrypt ${name} secret";
          };

          Service = {
            Type = "oneshot";
            ExecStart = "${decryptSecret name value}/bin/${name}-decrypt";
            Environment = "PATH=${makeBinPath [ pkgs.coreutils ]}";
          };

          Install = {
            WantedBy = [ "default.target" ];
          };
        })
    )
    cfg.file;

  # Options for a secret file
  # Based on https://github.com/ryantm/agenix/pull/58
  secretFile = types.submodule ({ name, ... }: {
    options = {
      path = mkOption {
        description = "Relative path of where the file will be saved in /run";
        type = types.str;
      };

      source = mkOption {
        description = "Path to the age encrypted file";
        type = types.path;
      };

      mode = mkOption {
        type = types.str;
        default = "0400";
        description = "Permissions mode of the decrypted file";
      };

      owner = mkOption {
        type = types.str;
        default = "$UID";
        description = "User of the decrypted file";
      };

      group = mkOption {
        type = types.str;
        default = "$(id -g)";
        description = "Group of the decrypted file";
      };

      symlinks = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Symbolically link decrypted file to absolute paths";
      };

      cpOnService = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Copy decrypted file to absolute paths";
      };
    };

    config = {
      path = mkDefault name;
    };
  });
in
{
  options.homeage = {
    file = mkOption {
      description = "Attrset of secret files";
      default = { };
      type = types.attrsOf secretFile;
    };

    pkg = mkOption {
      description = "(R)age package to use";
      default = pkgs.age;
      type = types.package;
    };

    isRage = mkOption {
      description = "Is rage package";
      default = false;
      type = types.bool;
    };

    mount = mkOption {
      description = "Absolute path to folder where decrypted files are stored. Files are decrypted on login. Defaults to /run which is a tmpfs.";
      default = "/run/user/$UID/secrets";
      type = types.str;
    };

    identityPaths = mkOption {
      description = "Absolute path to identity files used for age decryption. Must provide at least one path";
      default = [ ];
      type = types.listOf types.str;
    };
  };

  config = mkIf (cfg.file != { }) (mkMerge [
    {
      assertions = [{
        assertion = cfg.identityPaths != [ ];
        message = "secret.identityPaths must be set.";
      }];

      systemd.user.services = mkServices;
    }
  ]);
}
