## Options

**homeage.pkg**:

- *Description*: (R)age package to use
- *Default*: `pkgs.age`;
- *Type*: `types.package`;

**homeage.isRage**:

- *Description*: Is rage package
- *Default*: `false`;
- *Type*: `types.bool`;

**homeage.folder**:

- *Description*: Folder where encrypted age files are symlinked to
- *Default*: `"${config.home.homeDirectory}/secrets"`;
- *Type*: `types.str`;

**homeage.mount**:

- *Description*: Absolute path to folder where decrypted files are stored. Files are decrypted on login. Defaults to /run which is a tmpfs.
- *Default*: `/run/user/$UID/secrets`;
- *Type*: `types.str`;

**homeage.identityPaths**:

- *Description*: Absolute path to identity files used for age decryption. Must provide at least one path
- *Default*: `[ ]`;
- *Type*: `types.listOf types.str`;

**homeage.file**:

- *Description*: Attrset of secret files
- *Default*: `{ }`;
- *Type*: `types.attrsOf secretFile`;

**homeage.file.\<name\>**:

- *Description*: Name of the service unit that decrypts the secret (`{name}-secret`)

**homeage.file.\<name\>**:

- *Description*: Relative path of where the file will be saved (in secret folder and `/run`). `.age` is appended automatically to the encrypted file path.
- *Default*: none
- *Type*: `types.str`

**homeage.file.\<name\>.source**:

- *Description*: Path to the age encrypted file
- *Default*: none
- *Type*: `types.path`

**homeage.file.\<name\>.mode**:

- *Description*: Permissions mode of the decrypted file
- *Default*: `"0400"`
- *Type*: `types.str`

**homeage.file.\<name\>.owner**:

- *Description*: User of the decrypted file
- *Default*: `"$UID"`
- *Type*: `types.str`

**homeage.file.\<name\>.group**:

- *Description*: Group of the decrypted file
- *Default*: `"$(id -g)"`
- *Type*: `types.str`
