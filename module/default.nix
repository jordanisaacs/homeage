{ pkgs, config, options, lib, ... }:
with lib;

let
  cfg = config.homeage;

  # All files are decrypted to /run/user and cleaned up when rebooted
  runtimeDecryptFolder = "/run/user/$UID/secrets";

  ageBin = if cfg.isRage then "${cfg.pkg}/bin/rage" else "${cfg.pkg}/bin/age";

  # The lock file so only decrypts when activating home-manager and logging in for first time
  decryptLock = "${runtimeDecryptFolder}/lock";

  runtimeDecryptPath = path: runtimeDecryptFolder + "/" + path;
  encryptedPath = path: cfg.folder + "/" + path;
  identities = builtins.concatStringsSep " " (map (path: "-i ${path}") cfg.identityPaths);
  symlinks = secret: builtins.concatStringsSep "\n" (map (link: "ln -s ${secret.runtimepath} ${link}")) secret.links;

  # Script to decrypt an age file
  # From https://github.com/ryantm/agenix/pull/58
  decryptSecret = secretType: (
    let
      sourcePath = encryptedPath secretType.name;
    in
    builtins.concatStringsSep "\n" [
      ''
        echo "Decrypting secret ${secretType.encryptpath} to ${secretType.runtimepath}"
        TMP_FILE="${secretType.runtimepath}.tmp"
        mkdir $VERBOSE_ARG -p $(dirname ${secretType.runtimepath})
        (
          umask u=r,g=,o=
          ${ageBin} -d ${identities} -o "$TMP_FILE" "${secretType.encryptpath}"
        )
        chmod $VERBOSE_ARG ${secretType.mode} "$TMP_FILE"
        chown $VERBOSE_ARG ${secretType.owner}:${secretType.group} "$TMP_FILE"
        mv $VERBOSE_ARG -f "$TMP_FILE" "${secretType.runtimepath}"
      ''
      (symLinks secretType)
    ]
  );

  # Convert the file attributes to a list
  fileToList = files: map decryptSecret
    (attrsets.mapAttrsToList
      (name: value:
        {
          runtimepath = runtimeDecryptPath name;
          encryptpath = encryptedPath name;
          group = value.group;
          mode = value.mode;
          owner = value.owner;
          links = value.symlinks;
        }
      )
      files);

  # install secrets removes the lock file (forces a redecrypt)
  installSecrets = builtins.concatStringsSep "\n" [
    "$DRY_RUN_CMD rm -f ${decryptLock}"
    "$DRY_RUN_CMD ${decryptSecrets}/bin/decrypt"
  ];

  # decrypt secrets if lock file does not exist
  decryptSecrets = pkgs.writeShellScriptBin "decrypt" (builtins.concatStringsSep "\n" ([
    ''
      if [ -f "${decryptLock}" ]; then
        exit 1
      fi
    ''
  ] ++ (fileToList cfg.file) ++ [
    "touch ${decryptLock}"
  ]));

  # Modify our files into home.file format
  installFiles = lib.attrsets.mapAttrs'
    (name: value:
      lib.attrsets.nameValuePair
        ("${cfg.folder}/${name}" + ".age")
        ({
          source = value.source;
        })
    )
    cfg.file;

  # Options for a secret file
  # Based on https://github.com/ryantm/agenix/pull/58
  secretFile = types.submodule ({ config, ... }: {
    options = {
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

    folder = mkOption {
      description = "Absolute path to folder where encrypted age files are symlinked to";
      default = "${config.home.homeDirectory}/secrets";
      type = types.str;
    };

    startupPath = mkOption {
      description = "Absolute path to startup file which will run the decrypt script on startup";
      default = "${config.home.homeDirectory}/.profile";
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

      home.file = installFiles // {
        "${cfg.startupPath}".text = "${decryptSecrets}/bin/decrypt";
      };

      # Needs to be after linkGeneration as script uses symlinked paths
      home.activation.homeage = hm.dag.entryAfter [ "linkGeneration" ] installSecrets;
    }
  ]);
}
