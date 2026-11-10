{
  description = "Homeserver NixOS Flake Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    let
      # Build a system with the shared modules.
      mkSystem =
        system: hostModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = hostModules ++ [
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.jack = import ./home.nix;
              home-manager.extraSpecialArgs = { inherit inputs; };
            }
          ];
        };
    in
    {
      nixosConfigurations = {
        # Local home server. Runs Jellyfin and AdGuard Home.
        #
        # This used to be one of two hosts: a public VPS acted as a
        # WireGuard endpoint + Caddy TLS reverse proxy so the media server
        # was reachable from the internet without exposing the home IP. The VPS
        # and the WireGuard client that dialled it have been removed
        # entirely (see AGENTS.md), so this is now the only host. Remote
        # access is to be re-done with Tailscale.
        homeserver = mkSystem "x86_64-linux" [ ./hosts/homeserver/default.nix ];
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
