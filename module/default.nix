{ pkgs, config, options, lib, ... }:
with lib;

let
  cfg = config.homeage;

  ageBin = if cfg.isRage then "${cfg.pkg}/bin/rage" else "${cfg.pkg}/bin/age";
  startupDecryptPath = path: cfg.startupMount + "/" + path;
  activationDecryptPath = path: cfg.activationMount + "/" + path;


  identities = builtins.concatStringsSep " " (map (path: "-i ${path}") cfg.identityPaths);

  createFiles = command: runtimepath: destinations: builtins.concatStringsSep "\n" ((map (dest: ''
    mkdir -p $(dirname ${dest})
    ${command} ${runtimepath} ${dest}
  '')) destinations);

  decryptSecret = name: { source, decryptPath, mode, owner, group, lnOnStartup, cpOnStartup, ... }:
    let
      runtimepath = startupDecryptPath decryptPath;
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

  # Options for a secret file
  secretFile = types.submodule ({ name, ... }: {
    options = {
      source = mkOption {
        description = "Path to the age encrypted file";
        type = types.path;
      };

      decryptPath = mkOption {
        description = "Relative path (to startupMount and activationMount) where the decrypted file will be saved";
        type = types.str;
      };

      mode = mkOption {
        type = types.str;
        description = "Permissions mode of the decrypted file";
      };

      owner = mkOption {
        type = types.str;
        description = "User of the decrypted file";
      };

      group = mkOption {
        type = types.str;
        description = "Group of the decrypted file";
      };

      lnOnStartup = mkOption {
        type = types.listOf types.str;
        description = "Symbolically link on startup decrypted file to absolute paths";
      };

      lnOnActivation = mkOption {
        type = types.listOf types.str;
        description = "Symbolically link on activation decrypted file to absolute paths";
      };

      cpOnStartup = mkOption {
        type = types.listOf types.str;
        description = "Copy decrypted file on startup to absolute paths";
      };

      cpOnActivation = mkOption {
        type = types.listOf types.str;
        description = "Copy decrypted file on activation to absolute paths";
      };
    };

    config = {
      decryptPath = mkDefault name;

      mode = mkDefault "0400";
      owner = mkDefault "$UID";
      group = mkDefault "$(id -g)";

      lnOnStartup = mkDefault [ ];
      lnOnActivation = mkDefault [ ];

      cpOnStartup = mkDefault [ ];
      cpOnActivation = mkDefault [ ];
    };
  });
in
{
  options.homeage = {
    pkg = mkOption {
      type = types.package;
      description = "(R)age package to use";
    };

    isRage = mkOption {
      type = types.bool;
      description = "Whether homeage.pkg is rage package";
    };

    startupMount = mkOption {
      type = types.nullOr types.str;
      description = ''
        Absolute path to folder where startup decrypted files are stored.

        Defaults to /run which is a tmpfs. tmpfs still loads secrets to disk if using swap.
        Recommended to mount a ramfs (requires sudo) as it doesn't use swap and change the path to point there.
      '';
    };

    activationMount = mkOption {
      type = types.nullOr types.str;
      description = "Absolute path to folder where activation decrypted files are stored.";
    };

    identityPaths = mkOption {
      type = types.listOf types.str;
      description = "Absolute path to identity files used for age decryption. Must provide at least one path";
    };

    file = mkOption {
      description = ''
        Attribute set of secret files

        Activation vs. Startup Secrets:
        - Use activation if don't care about secrets being written to disk as they will only be decrypted once on activation.
        - Use startup if care about secrets being written to disk (see startupMount for filesystem info). It creates a systemd service/decryption script that runs on startup.

        Source decrypted file:
        - A source decrypted file (stored in appropriate mount folder) exists only if symlinks are used. Copies won't create a source file.

        Symlink vs. copy:
        - Use symbolic link as it ensures the secret is read only. ONLY use copy if a program doesn't allow for symlinked files. There are fewer checks on copied files.

        Activation Checks:
        - Activation succeeds if can successfully decrypt file
        - No paths interfere with other declared paths in current generation
        - No newly declared paths interfere with existing files
        - No files exist at declared symlinks

        Activation Cleanup:
        - Copies always ask for deletion (hence their discouraged use)
        - Links are only unlinked if point to declared path
        - Source files are deleted without asking

        Activation Startup:
        - Copies and symlinks overwrites existing files/links at destination
          - Note: the new path activation check prevents previously existing files/links from being overwritten
        - Systemd units and activation decryption runs if the attribute set has changed
      '';
      default = { };
      type = types.attrsOf secretFile;
    };
  };

  config = mkIf (cfg.file != { }) (mkMerge [
    {
      assertions =
        let
          makePathVal = path: { ${path} = 1; };
          pathsToCount = with builtins; list:
            map (path: makePathVal path) list;

          secretRuntimePaths =
            # [ { path1 = 1} { path2 = 1 } { path1 = 1 } { path3 = 1 }]
            concatLists
              # [ [ { path1 = 1} { path2 = 1 } ] [ { path1 = 1 } { path3 = 1 }]
              (mapAttrsToList
                (name: value:
                  (
                    (if (length value.lnOnStartup > 0 && cfg.startupMount != null) then [
                      (makePathVal (startupDecryptPath value.decryptPath))
                    ] else [ ]) ++
                    (if (length value.lnOnActivation > 0 && cfg.activationMount != null) then [
                      (makePathVal (activationDecryptPath value.decryptPath))
                    ] else [ ]) ++
                    (pathsToCount value.lnOnStartup) ++
                    (pathsToCount value.lnOnActivation) ++
                    (pathsToCount value.cpOnStartup) ++
                    (pathsToCount value.cpOnStartup)
                  )
                )
                cfg.file
              );


          allPaths = secretRuntimePaths ++ (mapAttrsToList
            (n: v: { "${config.home.homeDirectory}/${v.target}" = 1; })
            config.home.file);

          dupRuntimePaths =
            attrNames
              (filterAttrs
                (n: v: v > 1)
                (foldAttrs
                  (acc: v: acc + v)
                  0
                  allPaths
                )
              );

          dupsStr = concatStringsSep ", " dupRuntimePaths;

          hasActivationLinks = with builtins;
            filterAttrs (n: v: (length v.lnOnActivation) > 0) cfg.file;

          hasStartupLinks = with builtins;
            filterAttrs (n: v: (length v.lnOnStartup) > 0) cfg.file;
        in
        [
          ({
            assertion = cfg.identityPaths != [ ];
            message = "secret.identityPaths must be set.";
          })
          ({
            assertion = if hasActivationLinks != { } then cfg.activationMount != null else true;
            message = "Must set homeage.activationMount if using symlinked activation secrets";
          })
          ({
            assertion = if hasStartupLinks != { } then cfg.startupMount != null else false;
            message = "Must set homeage.startupMount if using symlinked startup secrets";
          })
          ({
            assertion = dupRuntimePaths == [ ];
            message = "Conflicting managed target files (including secrets): ${dupsStr}";
          })
        ];

      systemd.user.services = mkServices;

      homeage = {
        pkg = lib.mkDefault pkgs.age;
        isRage = lib.mkDefault false;
        identityPaths = lib.mkDefault [ ];
        startupMount = lib.mkDefault "/run/user/$UID/secrets";
        activationMount = lib.mkDefault null;
      };
    }
  ]);
}
