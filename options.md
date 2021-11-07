## Options

**secrets.pkg**:

- *Description*: (R)age package to use
- *Default*: `pkgs.age`;
- *Type*: `types.package`;

**secrets.isRage**:

- *Description*: Is rage package
- *Default*: `false`;
- *Type*: `types.bool`;

**secrets.folder**:

- *Description*: Folder where encrypted age files are symlinked to
- *Default*: `"${config.home.homeDirectory}/secrets"`;
- *Type*: `types.str`;

**secrets.startupPath**:

- *Description*: Absolute path to startup file which will run the decrypt script on startup
- *Default*: `"${config.home.homeDirectory}/.profile"`;
- *Type*: `types.str`;

**secrets.startupPath**:

- *Description*: Absolute path to startup file which will run the decrypt script on startup
- *Default*: `"${config.home.homeDirectory}/.profile"`;
- *Type*: `types.str`;

**secrets.identityPaths**:

- *Description*: Absolute path to identity files used for age decryption. Must provide at least one path
- *Default*: `[ ]`;
- *Type*: `types.listOf types.str`;

**secrets.file**:

- *Description*: Attrset of secret files
- *Default*: `{ }`;
- *Type*: `types.attrsOf secretFile`;

**secrets.file.<name>**:

- *Description*: Path of where the file will be saved (after the base paths)

**secrets.file.<name>.source**:

- *Description*: Path to the age encrypted file
- *Default*: none
- *Type*: `types.path`

**secrets.file.<name>.mode**:

- *Description*: Permissions mode of the decrypted file
- *Default*: `"0400"`
- *Type*: `types.str`

**secrets.file.<name>.owner**:

- *Description*: User of the decrypted file
- *Default*: `"$UID"`
- *Type*: `types.str`

**secrets.file.<name>.group**:

- *Description*: Group of the decrypted file
- *Default*: `"$(id -g)"`
- *Type*: `types.str`




