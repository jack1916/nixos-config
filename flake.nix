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
    #
    # PINNED, do not use the default branch: sops-nix master bumped its
    # go.mod to `go 1.26.0`, while nixpkgs 25.11 only ships Go 1.25.10, so
    # sops-install-secrets fails to build with:
    #   go: go.mod requires go >= 1.26.0 (running go 1.25.10; GOTOOLCHAIN=local)
    # This commit is the newest one still declaring `go 1.25.0`.
    # Drop the pin (and sopsVendorHash below) once nixpkgs 25.11 carries
    # Go 1.26.
    sops-nix.url = "github:Mic92/sops-nix/99f94cc870dfd948bbae62ba541f14a7a4ddf6a2";
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
      # This pinned sops-nix commit ships a vendorHash matching its own
      # dependency set, which does not match what Go 1.25 resolves against
      # nixpkgs 25.11. Rather than fork sops-nix, override just the hash.
      # The value below is the `got:` hash reported by the failing build:
      #   specified: sha256-KUP+FymwWdlygPM36QLQlWKTkDuVPhvYbyOc9snJOI4=
      #   got:       sha256-dCyJnJginwaj1Jynd3E/NP3vXe2HcpEXqiNdg36Uk5U=
      sopsVendorHash = "sha256-dCyJnJginwaj1Jynd3E/NP3vXe2HcpEXqiNdg36Uk5U=";

      # Build a system with the shared modules plus the sops hash fix.
      mkSystem =
        system: hostModules:
        let
          pkgsFor = nixpkgs.legacyPackages.${system};
          # NOTE: the sops module defaults `sops.package` to
          #   (pkgs.callPackage ../.. { }).sops-install-secrets
          # which re-invokes sops-nix with the DEFAULT vendorHash, so an
          # overlay cannot influence it. Override the package explicitly,
          # along with validationPackage (which callPackages separately).
          patchedSops = (pkgsFor.callPackage inputs.sops-nix { }).sops-install-secrets.override {
            vendorHash = sopsVendorHash;
          };
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = hostModules ++ [
            home-manager.nixosModules.home-manager
            inputs.sops-nix.nixosModules.sops
            {
              sops.package = patchedSops;
              sops.validationPackage = patchedSops;
            }
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

      # Passthrough so `nix run .#disko` works, e.g. for a dry-activate of
      # hosts/vps/disko.nix before touching /dev/sda.
      packages.x86_64-linux.disko = inputs.disko.packages.x86_64-linux.disko;

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
