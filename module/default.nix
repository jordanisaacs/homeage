{
  pkgs,
  config,
  options,
  lib,
  ...
}:
with lib; let
  cfg = config.homeage;

  ageBin =
    if cfg.isRage
    then "${cfg.pkg}/bin/rage"
    else "${cfg.pkg}/bin/age";

  statePath = "homeage/state.json";
  runtimeDecryptPath = path: runtimeDecryptFolder + "/" + path;

  identities = builtins.concatStringsSep " " (map (path: "-i ${path}") cfg.identityPaths);

  # Creates the directory and runs the command to connect the source file to destination
  createFiles = command: path: dests:
    concatStringsSep "\n" ((map (dest: ''
        mkdir -p $(dirname ${dest})
        ${command} ${path} ${dest}
      ''))
      dests);

  decryptSecret = name: {
    source,
    path,
    symlinks,
    cpOnService,
    mode,
    owner,
    group,
    ...
  }: let
    linksCmds = createFiles "ln -sf" path symlinks;
    copiesCmds = createFiles "cp -f" path cpOnService;
  in
    pkgs.writeShellScriptBin "${name}-decrypt" ''
      set -euo pipefail

      echo "Decrypting secret ${source} to ${decryptpath}"
      TMP_FILE="${decryptpath}.tmp"
      mkdir -p $(dirname ${decryptpath})
      (
        umask u=r,g=,o=
        ${ageBin} -d ${identities} -o "$TMP_FILE" "${source}"
      )
      chmod ${mode} "$TMP_FILE"
      chown ${owner}:${group} "$TMP_FILE"
      mv -f "$TMP_FILE" "${decryptpath}"
      ${linksCmds}
      ${copiesCmds}
    '';

  mkServices =
    lib.attrsets.mapAttrs'
    (
      name: value:
        lib.attrsets.nameValuePair
        "${name}-secret"
        {
          Unit = {
            Description = "Decrypt ${name} secret";
          };

          Service = {
            Type = "oneshot";
            ExecStart = "${decryptSecret name value}/bin/${name}-decrypt";
            Environment = "PATH=${makeBinPath [pkgs.coreutils]}";
          };

          Install = {
            WantedBy = ["default.target"];
          };
        }
    )
    cfg.file;

  # Options for a secret file
  # Based on https://github.com/ryantm/agenix/pull/58
  secretFile = {
    name,
    config,
    ...
  }: {
    options = {
      path = mkOption {
        description = "Path of where the file will be decrypted";
        default = "${cfg.mount}/${name}";
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
        default = [];
        description = "Symbolically link decrypted file to absolute paths";
      };

      cpOnService = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Copy decrypted file to absolute paths";
      };
    };
  };
in {
  options.homeage = {
    secrets = mkOption {
      description = "Attrset of secret files";
      default = {};
      type = with types; attrsOf (submodule secretFile);
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
      description = "Absolute path to folder where decrypted files are stored by default. Files are decrypted on login. Defaults to /run which is a tmpfs.";
      default = "/run/user/$UID/secrets";
      type = types.str;
    };

    identityPaths = mkOption {
      description = "Absolute path to identity files used for age decryption. Must provide at least one path";
      default = [];
      type = types.listOf types.str;
    };

    cleanup = mkOption {
      description = ''
        Cleans up the outdated decrypted files and symlinks on activation. Secret file is assumed to not have been modified and is always deleted.

        Cases when cp file/symlink is not removed:
        1. Symlink when not pointing to the original secret path.
        2. cp'd file when original secret file does not exist (can't verify they weren't modified).
        3. cp'd file when it does not match the original secret file (using `cmp`)
      '';
      default = true;
    };
  };

  config = mkIf (cfg.secrets != {}) (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.identityPaths != [];
          message = "secret.identityPaths must be set.";
        }
      ];

      home = {
        extraBuilderCommands = let
          stateFile =
            pkgs.writeText
            "homeage-state.json"
            (builtins.toJSON
              (map
                (secret: secret)
                (builtins.attrValues cfg.secrets)));
        in ''
          mkdir -p $(dirname $out/${statePath})
          ln -s ${stateFile} $out/${statePath}
        '';

        activation = {
          homeageDecryptionCheck = let
            decryptSecretScript = name: source: ''
              if ! ${ageBin} -d ${identities} -o /dev/null ${source} 2>/dev/null ; then
                DECRYPTION="''${DECRYPTION}[homeage] Failed to decrypt ${name}\n""
              fi
            '';

            checkDecryptionScript = builtins.concatStringsSep "\n" ([
                "DECRYPTION="
              ]
              ++ (lib.mapAttrsToList (n: v: decryptSecretScript n v.source) cfg.file)
              ++ [
                ''
                  if [ ! -x "$DECRYPTION" ]; then
                    printf "''${errorColor}''${DECRYPTION}[homeage] Check homage.identityPaths to either add an identity or remove a broken one\n''${normalColor}" 1>&2
                    exit 1
                  fi
                ''
              ]);
          in
            hm.dag.entryBefore ["writeBoundary"] checkDecryptionScript;

          homeageFileCleanup = let
            fileCleanup = ''
              # oldGenPath and newGenPath come from activation init:
              # https://github.com/nix-community/home-manager/blob/master/modules/lib-bash/activation-init.sh
              if [[ ! -v oldGenPath ]] ; then
                echo "[homeage] No previous generation: no cleanup needed."
                return 0
              fi

              local oldGenFile newGenFile
              oldGenFile="$oldGenPath/${statePath}"
              newGenFile="$newGenPath/${statePath}"

              # Technically not possible (state always written if has secrets). Check anyway
              if [ ! -L "$newGenFile" ]; then
                echo "[homeage] Activated but no current state" >&2
                return 1
              fi

              if [ ! -L "$oldGenFile" ]; then
                echo "[homeage] No previous homeage state: no cleanup needed"
                return 0
              fi

              ${pkgs.jq}/bin/jq \
                --null-input \
                --compact-output \
                --argfile old "$oldGenFile" \
                --argfile new "$newGenFile" \
                '$old - $new | .[]' |
              while IFS=$"\n" read -r c; do
                path=$(echo "$c" | jq --raw-output '.path')
                symlinks=$(echo "$c" | jq --raw-output '.symlinks[]')
                files=$(echo "$c" | jq --raw-output '.cpOnService[]')

                echo "[homeage] Cleaning up decrypted secret: $path\n"

                for symlink in "''${symlinks[@]}"; do
                  if [ ! "$(readlink "$symlink")" == "$path" ]; then
                    echo "[homeage] Not removing symlink $symlink as it does not point to secret.\n"
                    continue
                  fi

                  echo "[homeage] Removing symlink $symlink...\n"
                  unlink "$symlink"
                  rmdir --ignore-fail-on-non-empty --parents "$(dirname "$symlink")"
                done

                for file in "''${files[@]}"; do
                  if [ ! -f "$path" ]; then
                    echo "[homeage] Not removing cp'd file $file because secret does not exist so can't verify wasn't modified.\n"
                    continue
                  fi

                  if [ ! cmp -s "$path" ]; then
                    echo "[homeage] Not removing cp'd file $file because it was modified.\n"
                    continue
                  fi

                  echo "[homeage] Removing file $file..."
                  rm "$file"
                  rmdir --ignore-fail-on-non-empty --parents "$(dirname "$file")"
                done

                if [ ! -f "$path" ]; then
                  echo "[homeage] Not removing secret file $path because does not exist.\n"
                  continue
                else
                  echo "[homeage] Removing secret file $path...\n"
                  rm "$path"
                  rmdir --ignore-fail-on-non-empty --parents "$(dirname "$path")"
                fi
              done
            '';
          in
            hm.dag.entryBetween ["reloadSystemd"] ["writeBoundary"] fileCleanup;
        };
      };

      systemd.user.services = mkServices;
    }
  ]);
}
