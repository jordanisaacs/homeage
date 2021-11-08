{ pkgs, config, options, lib, ... }:
with lib;

let
  cfg = config.homeage;

  # All files are decrypted to /run/user and cleaned up when rebooted
  runtimeDecryptFolder = cfg.mount;

  ageBin = if cfg.isRage then "${cfg.pkg}/bin/rage" else "${cfg.pkg}/bin/age";

  runtimeDecryptPath = path: runtimeDecryptFolder + "/" + path;
  encryptedPath = path: cfg.folder + "/" + path + ".age";

  identities = builtins.concatStringsSep " " (map (path: "-i ${path}") cfg.identityPaths);
  createLinks = runtimepath: symlinks: builtins.concatStringsSep "\n" ((map (link: "ln -sf ${runtimepath} ${link}")) symlinks);

  decryptSecret = name: { path, symlinks, mode, owner, group, ... }:
    let
      runtimepath = runtimeDecryptPath path;
      encryptpath = encryptedPath path;
      links = createLinks runtimepath symlinks;
    in
    pkgs.writeShellScriptBin "${name}-decrypt" ''
      ${pkgs.coreutils}/bin/echo "Decrypting secret ${encryptpath} to ${runtimepath}"
      TMP_FILE="${runtimepath}.tmp"
      ${pkgs.coreutils}/bin/mkdir $VERBOSE_ARG -p $(${pkgs.coreutils}/bin/dirname ${runtimepath})
      (
        umask u=r,g=,o=
        ${ageBin} -d ${identities} -o "$TMP_FILE" "${encryptpath}"
      )
      ${pkgs.coreutils}/bin/chmod $VERBOSE_ARG ${mode} "$TMP_FILE"
      ${pkgs.coreutils}/bin/chown $VERBOSE_ARG ${owner}:${group} "$TMP_FILE"
      ${pkgs.coreutils}/bin/mv $VERBOSE_ARG -f "$TMP_FILE" "${runtimepath}"
      ${links}
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
          };

          Install = {
            WantedBy = [ "default.target" ];
          };
        })
    )
    cfg.file;

  # Modify our files into home.file format
  installFiles = lib.attrsets.mapAttrs'
    (name: value:
      lib.attrsets.nameValuePair
        (encryptedPath value.path)
        ({
          source = value.source;
        })
    )
    cfg.file;

  # Options for a secret file
  # Based on https://github.com/ryantm/agenix/pull/58
  secretFile = types.submodule ({ config, ... }: {
    options = {
      path = mkOption {
        description = "Relative path of where the file will be saved (in secret folder and /run). .age is appended automatically to the encrypted file path.";
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

    folder = mkOption {
      description = "Absolute path to folder where encrypted age files are symlinked to";
      default = "${config.home.homeDirectory}/secrets";
      type = types.str;
    };

    identityPaths = mkOption {
      description = "Absolute path to identity files used for age decryption. Must provide at least one path";
      default = [ ];
      type = types.listOf types.str;
    };

    decryptScriptPath = mkOption {
      description = "Absolute path of decryption script. Must be called on login";
      default = "${config.home.homeDirectory}/.profile";
      type = types.str;
    };
  };

  config = mkIf (cfg.file != { }) (mkMerge [
    {
      assertions = [{
        assertion = cfg.identityPaths != [ ];
        message = "secret.identityPaths must be set.";
      }];

      home.file = installFiles;

      systemd.user.services = mkServices;
    }
  ]);
}
