{
  description = "My Homeserver + VPS NixOS Flake Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Declarative disk partitioning, used both by nixos-anywhere at install
    # time and by hosts/vps/default.nix at runtime.
    disko.url = "github:nix-community/disko/v1.12.0";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Secret deployment (WireGuard keys). Secrets themselves are encrypted
    # in secrets/ and never committed in plaintext.
    sops-nix.url = "github:Mic92/sops-nix";
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
      # Shared settings applied to every host.
      commonModules = [
        home-manager.nixosModules.home-manager
        inputs.sops-nix.nixosModules.sops
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.jack = import ./home.nix;
          home-manager.extraSpecialArgs = { inherit inputs; };
        }
      ];
    in
    {
      nixosConfigurations = {
        # Existing local home server (Plex already fully configured here).
        homeserver = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            ./hosts/homeserver/default.nix
            ./hosts/homeserver/wireguard-client.nix
          ]
          ++ commonModules;
        };

        # Public gateway VPS: WireGuard endpoint + Caddy TLS reverse proxy.
        vps = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            ./hosts/vps/default.nix
          ]
          ++ commonModules;
        };
      };

      # Passthrough so `nix run .#disko` works, e.g. for a dry-activate of
      # hosts/vps/disko.nix before touching /dev/sda.
      packages.x86_64-linux.disko = inputs.disko.packages.x86_64-linux.disko;

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
