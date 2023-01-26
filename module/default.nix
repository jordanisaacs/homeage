{
  pkgs,
  config,
  options,
  lib,
  ...
}:
with lib; let
  cfg = config.homeage;

  ageBin = let
    binName = (builtins.parseDrvName cfg.pkg.name).name;
  in "${cfg.pkg}/bin/${binName}";

  jq = lib.getExe pkgs.jq;

  identities = builtins.concatStringsSep " " (map (path: "-i ${path}") cfg.identityPaths);

  createFiles = command: runtimepath: destinations:
    builtins.concatStringsSep "\n" ((map (dest: ''
        $DRY_RUN_CMD mkdir $VERBOSE_ARG -p $(dirname ${dest})
        $DRY_RUN_CMD ${command} $VERBOSE_ARG ${runtimepath} ${dest}
      ''))
      destinations);

  statePath = "homeage/state.json";

  decryptSecret = name: {
    source,
    path,
    symlinks,
    copies,
    mode,
    owner,
    group,
    ...
  }: let
    linksCmds = createFiles "ln -sf" path symlinks;
    copiesCmds = createFiles "cp -f" path copies;
  in ''
    echo "Decrypting secret ${source} to ${path}"
    TMP_FILE="${path}.tmp"
    $DRY_RUN_CMD mkdir $VERBOSE_ARG -p $(dirname ${path})
    (
      $DRY_RUN_CMD umask u=r,g=,o=
      $DRY_RUN_CMD ${ageBin} -d ${identities} -o "$TMP_FILE" "${source}"
    )
    $DRY_RUN_CMD chmod $VERBOSE_ARG ${mode} "$TMP_FILE"
    $DRY_RUN_CMD chown $VERBOSE_ARG ${owner}:${group} "$TMP_FILE"
    $DRY_RUN_CMD mv $VERBOSE_ARG -f "$TMP_FILE" "${path}"
    ${linksCmds}
    ${copiesCmds}
  '';

  cleanupSecret = prefix: ''
    echo "${prefix}Cleaning up decrypted secret: $path"

    # Cleanup symlinks
    for symlink in ''${symlinks[@]}; do
      if [ ! "$(readlink "$symlink")" == "$path" ]; then
        echo "${prefix}Not removing symlink $symlink as it does not point to secret."
        continue
      fi
      echo "${prefix}Removing symlink $symlink..."
      unlink "$symlink"
      rmdir --ignore-fail-on-non-empty --parents "$(dirname "$symlink")"
    done

    # Cleanup copies
    for copy in ''${copies[@]}; do
      if [ ! -f $path ]; then
        echo "${prefix}Not removing copied file $copy because secret does not exist so can't verify wasn't modified."
        continue
      fi
      if ! cmp -s "$copy" "$path"; then
        echo "${prefix}Not removing copied file $copy because it was modified."
        continue
      fi
      echo "${prefix}Removing copied file $copy..."
      rm "$copy"
      rmdir --ignore-fail-on-non-empty --parents "$(dirname "$copy")"
    done

    # Cleanup decrypted secret
    if [ ! -f "$path" ]; then
      echo "${prefix}Not removing secret file $path because does not exist."
      continue
    else
      echo "${prefix}Removing secret file $path..."
      rm "$path"
      rmdir --ignore-fail-on-non-empty --parents "$(dirname "$path")"
    fi
  '';

  activationFileCleanup = isActivation: ''
    function homeageCleanup() {
      # oldGenPath and newGenPath come from activation init:
      # https://github.com/nix-community/home-manager/blob/master/modules/lib-bash/activation-init.sh
      if [ ! -v oldGenPath ] ; then
        echo "[homeage] No previous generation: no cleanup needed."
        return 0
      fi

      local oldGenFile newGenFile
      oldGenFile="$oldGenPath/${statePath}"
      ${
      lib.optionalString isActivation ''
        local newGenFile
        newGenFile="$newGenPath/${statePath}"

        # Technically not possible (state always written if has secrets). Check anyway
        if [ ! -L "$newGenFile" ]; then
          echo "[homeage] Activated but no current state" >&2
          return 1
        fi
      ''
    }

      if [ ! -L "$oldGenFile" ]; then
        echo "[homeage] No previous homeage state: no cleanup needed"
        return 0
      fi

      # Get all changed secrets for cleanup (intersection)
      ${jq} \
        --null-input \
        --compact-output \
        --argfile old "$oldGenFile" \
        ${
      if isActivation
      then ''
        --argfile new "$newGenFile" \
        '$old - $new | .[]' |
      ''
      else ''
        '$old | .[]' |
      ''
    }
      # Replace $UID with $(id -u). Don't use eval
      ${pkgs.gnused}/bin/sed \
        "s/\$UID/$(id -u)/g" |
      while IFS=$"\n" read -r c; do
        path=$(echo "$c" | ${jq} --raw-output '.path')
        symlinks=$(echo "$c" | ${jq} --raw-output '.symlinks[]')
        copies=$(echo "$c" | ${jq} --raw-output '.copies[]')

        ${cleanupSecret "[homeage] "}
      done
      echo "[homeage] Finished cleanup of secrets."
    }

    homeageCleanup
  '';

  # Options for a secret file
  # Based on https://github.com/ryantm/agenix/pull/58
  secretType = types.submodule ({ name, ... }: {
    options = {
      path = mkOption {
        description = "Absolute path of where the file will be saved. Defaults to mount/name";
        type = types.str;
        default = "${cfg.mount}/${name}";
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

      copies = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Copy decrypted file to absolute paths";
      };
    };
  });
in {
  options.homeage = {
    secrets = mkOption {
      description = "Attrset of secrets";
      default = { };
      type = types.attrsOf secretType;
    };

    pkg = mkOption {
      description = "(R)age package to use. Detects if using rage and switches to `rage` as the command rather than `age`";
      default = pkgs.age;
      type = types.package;
    };

    mount = mkOption {
      description = "Absolute path to folder where decrypted files are stored. Files are decrypted on login. Defaults to /run which is a tmpfs.";
      default = "/run/user/$UID/secrets";
      type = types.str;
    };

    identityPaths = mkOption {
      description = "Absolute path to identity files used for age decryption. Must provide at least one path";
      default = [];
      type = types.listOf types.str;
    };

    installationType = mkOption {
      description = ''
        Specify the way how secrets should be installed. Either via systemd user services (<literal>systemd</literal>)
        or during the activation of the generation (<literal>activation</literal>).
        </para><para>
        Note: Keep in mind that symlinked secrets will not work after reboots with <literal>activation</literal> if
        <literal>homeage.mount</literal> does not point to persistent location.

        Cleanup notes:
        * Systemd performs cleanup when service stops.
        * Activation performs cleanup after write boundary during activation.
        * When switching from systemd to activation, may need to activate twice.
          Because stopping systemd services, and thus cleanup, happens after
          activation decryption. Only occurs on the first activation.

        Cases when copied file/symlink is not removed:
        1. Symlink does not point to the decrypted secret file.
        2. Any copied file when the original secret file does not exist (can't verify they weren't modified).
        3. Copied file when it does not match the original secret file (using `cmp`).
      '';
      default = "systemd";
      type = types.enum ["activation" "systemd"];
    };
  };

  config = mkIf (cfg.secrets != {}) (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.identityPaths != [];
          message = "secret.identityPaths must be set.";
        }
        {
          assertion = let
            paths = mapAttrsToList (_: value: value.path) cfg.secrets;
          in
            (unique paths) == paths;
          message = "overlapping secret file paths.";
        }
      ];

      # Decryption check is enabled for all installation types
      home.activation.homeageDecryptCheck = let
        decryptCheckScript = name: source: ''
          if ! ${ageBin} -d ${identities} -o /dev/null ${source} 2>/dev/null ; then
            DECRYPTION="''${DECRYPTION}[homeage] Failed to decrypt ${name}\n"
          fi
        '';

        checkDecryptionScript = ''
          DECRYPTION=
          ${
            builtins.concatStringsSep "\n"
            (lib.mapAttrsToList (n: v: decryptCheckScript n v.source) cfg.secrets)
          }
          if [ ! -x $DECRYPTION ]; then
            printf "''${errorColor}''${DECRYPTION}[homeage] Check homage.identityPaths to either add an identity or remove a broken one\n''${normalColor}" 1>&2
            exit 1
          fi
        '';
      in
        hm.dag.entryBefore ["writeBoundary"] checkDecryptionScript;
    }
    (mkIf (cfg.installationType == "activation") {
      home = {
        # Always write state if activation installation so will
        # cleanup the previous generations when cleanup gets enabled
        # Do not write if systemd installation because cleanup will be done through systemd units
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
          homeageCleanup = let
            fileCleanup = activationFileCleanup true;
          in
            hm.dag.entryBetween ["homeageDecrypt"] ["writeBoundary"] fileCleanup;

          homeageDecrypt = let
            activationScript = builtins.concatStringsSep "\n" (lib.attrsets.mapAttrsToList decryptSecret cfg.secrets);
          in
            hm.dag.entryBetween ["reloadSystemd"] ["writeBoundary"] activationScript;
        };
      };
    })
    (mkIf (cfg.installationType == "systemd") {
      # Need to cleanup secrets if switching from activation -> systemd
      home.activation.homeageCleanup = let
        fileCleanup = activationFileCleanup false;
      in
        hm.dag.entryAfter ["writeBoundary"] fileCleanup;

      systemd.user.services = let
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
                  Environment = "PATH=${makeBinPath [pkgs.coreutils pkgs.diffutils]}";
                  ExecStart = "${pkgs.writeShellScript "${name}-decrypt" ''
                    set -euo pipefail
                    DRY_RUN_CMD=
                    VERBOSE_ARG=

                    ${decryptSecret name value}
                  ''}";
                  RemainAfterExit = true;
                  ExecStop = "${pkgs.writeShellScript "${name}-cleanup" ''
                    set -euo pipefail

                    path="${value.path}"
                    symlinks=(${builtins.concatStringsSep " " value.symlinks})
                    copies=(${builtins.concatStringsSep " " value.copies})

                    ${cleanupSecret ""}
                  ''}";
                };

                Install = {
                  WantedBy = ["default.target"];
                };
              }
          )
          cfg.secrets;
      in
        mkServices;
    })
  ]);
}
