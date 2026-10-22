{
  description = "My Homeserver + VPS NixOS Flake Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Secret deployment (WireGuard keys). Secrets themselves are encrypted
    # in secrets/ and never committed in plaintext.
    #
    # Tracks master. This previously needed pinning: sops-nix required Go
    # 1.26 while nixpkgs 25.11 shipped only Go 1.25.10, so
    # sops-install-secrets failed to build.
    # Switching this flake to nixos-unstable provides Go 1.26, so the pin
    # (and the vendorHash override it required) is no longer needed.
    sops-nix.url = "github:Mic92/sops-nix/master";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    let

      # Build a system with the shared modules plus the sops hash fix.
      mkSystem =
        system: hostModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = hostModules ++ [
            home-manager.nixosModules.home-manager
            inputs.sops-nix.nixosModules.sops
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
        # Existing local home server (Plex already fully configured here).
        homeserver = mkSystem "x86_64-linux" [
          ./hosts/homeserver/default.nix
          ./hosts/homeserver/wireguard-client.nix
        ];

        # Public gateway VPS: WireGuard endpoint + Caddy TLS reverse proxy.
        vps = mkSystem "x86_64-linux" [ ./hosts/vps/default.nix ];
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
