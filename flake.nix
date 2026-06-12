{
  description = "nix-darwin Wi-Fi aware WireGuard launchd modules";

  outputs =
    { self }:
    {
      darwinModules.default = self.darwinModules.wifi-wireguard;
      darwinModules.wifi-wireguard = import ./modules/darwin/wifi-wireguard.nix;

      homeManagerModules.default = self.homeManagerModules.swiftbar-status;
      homeManagerModules.swiftbar-status = import ./modules/home-manager/swiftbar-status.nix;
    };
}
