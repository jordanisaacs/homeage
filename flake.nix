{
  description = "Home manager secret management with age";

  outputs = {
    self,
    nixpkgs,
  }: {
    homeManagerModules.homeage = import ./module;
  };
}
