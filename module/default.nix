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

  decryptSecret = name: { source, decryptPath, lnOnStartup, cpOnStartup, mode, owner, group, ... }:
    let
      runtimepath = runtimeDecryptPath decryptPath;
      linksCmds = createFiles "ln -sf" runtimepath lnOnStartup;
      copiesCmds = createFiles "cp -f" runtimepath cpOnStartup;
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

  secretState =
    if (cfg.file != { }) then
      (lib.attrsets.mapAttrs'
        (name: value:
          lib.attrsets.nameValuePair
            (value.path)
            ({
              source = value.source;
              symlinks = value.symlinks;
              copies = value.cpOnService;
            })
        )
        cfg.file) else { };

  stateFile = with builtins; toFile "homeage-state" (toJSON {
    inherit secretState;
    mount = cfg.mount;
  });

  statePath = "homeage/stateFile.json";

  cleanupScript =
    let
      cleanupFunction = ''
        homeageCleanup() {
          # oldGenPath and newGenPath come from activation init:
          # https://github.com/nix-community/home-manager/blob/master/modules/lib-bash/activation-init.sh
          if [[ ! -v oldGenPath ]] ; then
            echo "No previous generation: no cleanup needed."
            return
          fi

          echo "Cleaning up decrypted secrets (mounted, copied, and linked)"

          local oldGenFile newGenFile
          oldGenFile="$oldGenPath/${statePath}"
          newGenFile="$newGenPath/${statePath}"

          echo $newGenFile

          # Technically not possible (state always written if has secrets). Check anyway
          if [ ! -L "$newGenFile" ] || [ ! -e "$newGenFile" ]; then
            echo "Homeage is activated but no current state" >&2
            return 1
          fi

          if [ ! -L "$oldGenFile" ] || [ ! -e "$oldGenFile" ] ; then
            echo "No previous homeage state: no cleanup needed" 
            return
          fi


          if [ "$(cat "$oldGenFile")" = "{}" ] ; then
            echo "Old state has no secrets: no cleanup needed"
            return
          fi
          
          local mountPath mergedState
          mountPath=$(getMount "$oldGenFile")
          mergedState=$(mergeJSON "$oldGenFile" "$newGenFile")

          echo "$mergedState"

          local intersectedPaths
          intersectedSecretPaths=$(intersectPath "$mergedState")

          # Iterate through each intersected path
          local secretPath secretPathB64 oldAttrs
          local symlinks b64symlink symlink
          local copies b64copy copy
          for secretPathB64 in $intersectSecretsPath ; do
              secretPath=$(echo $secretPathB64 | base64 --decode)
              oldAttrs=$(pathAttrs "$oldGenFile" "$secretPath")
              echo "Cleaning up secret: $secretPath"

              copies=$(attrList "$oldAttrs" "copies")
              for b64copy in $copies ; do
                  copy=$(echo $b64copy | base64 --decode)
                  echo "Removing copy: $copy"
              done


              symlinks=$(attrList "$oldAttrs" "symlinks")
              for b64symlink in $symlinks ; do
                  symlink=$(echo $b64symlink | base64 --decode)
                  echo "Unlinking: $symlink"
              done


              echo "Removing source secret: $mountPath/$secretPath"
          done
        }
      '';

      jqFunctions = ''
        PATH=$PATH:${pkgs.jq}/bin/jq

        # Get mount path
        # $1: State file
        getMount () {
          local result=$(jq -r '.mount' "$1")
          echo $result
        }

        # Merge json files.
        # $1: Old state file
        # $2: New state file
        mergeJSON () {
          local result=$(jq -s '{ s1: .[0] } + { s2: .[1] }' "$1" "$2")
          echo $result
        }

        # Get intersection of paths.
        # $1: Merged json string
        intersectPath () {
          local result=$(echo $1 | jq -r '( .s1.secretState | keys ) - ( .s2.secretState | keys ) | .[] | @base64')
          echo $result
        }

        # Get attributes of secret using the path
        # $1: State file
        pathAttrs () {
          local result=$(jq --arg TP $(echo "$2") '.secretState[$TP]' "$1")
          echo $result
        }

        # Get b64 encoded list from a secret path attribute
        # $1: Secret attributes string
        # $2: Attribute to extract list from
        attrList () {
          local result=$(echo $1 | jq -r --arg ATTR $(echo $2) '.[$ATTR] | .[] | @base64')
          echo $result
        }

        # Get union of paths.
        # $1: Merged json string
        unionPath () {
          local result=$(echo "$1" | jq '( .s1 | keys ) - (( .s1 | keys) - ( .s2 | keys ))')
          echo $result
        }

        # Gets values of a path
        # $1: mergeJSON result
        # $2: path name
        pathVals () {
          local result=$(echo "$1" | jq --arg TP $(echo "$2") '{ p1: s1[$TP], p2: .s2[$TP] }')
          echo $result
        }

        # Get the intersection of a path attribute
        # $1: pathVals result
        # $2: attribute name (either "symlinks" or "copies")
        intersectPathAttr () {
          local result=$(echo "$1" | jq --arg ATTR $(echo "$2") '(.p1[$ATTR]) - (.p2[$ATTR)')
          echo $result
        }
      '';

      cleanupHelpers = ''
        rmRecursiveDir () {
            # Recursively remove empty parent directories
            echo hi
        }

        unlinkPath () {
            # Unlink if points to source secret
            echo hi
        }

        rmCopy () {
          # Remove if file == source secret
          # https://stackoverflow.com/questions/12900538/fastest-way-to-tell-if-two-files-have-the-same-contents-in-unix-linux
          echo hi
        }
      '';
    in
    builtins.concatStringsSep "\n" [
      jqFunctions
      cleanupHelpers
      cleanupFunction
      "homeageCleanup"
    ];

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

  config = mkMerge [
    (mkIf (cfg.file != { }) {
      assertions = [{
        assertion = cfg.identityPaths != [ ];
        message = "secret.identityPaths must be set.";
      }];

      systemd.user.services = mkServices;
    })
    ({
      home.activation.homageCleanup = hm.dag.entryAfter [ "writeBoundary" ] cleanupScript;

      home.extraBuilderCommands = ''
        mkdir -p $(dirname $out/${statePath})
        ln -s ${stateFile} $out/${statePath}
      '';
    })
  ];
}
