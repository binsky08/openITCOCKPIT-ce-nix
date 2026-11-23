{
  description = "openITCOCKPIT Community Edition as rootless podman containers on NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules = {
        openitcockpit = ./nix/module.nix;
        default = self.nixosModules.openitcockpit;
      };

      checks = forAllSystems (pkgs: {
        # Pure evaluation: option defaults, generated env file, units, nginx.
        eval = import ./tests/eval.nix { inherit pkgs self nixpkgs; };
        # Offline NixOS VM test of the module mechanics with small images.
        vm-basic = import ./tests/vm-basic.nix { inherit pkgs self; };
      });

      packages = forAllSystems (pkgs: {
        # Interactive VM with internet access running the real stack:
        #   nix run .#vm   ->   https://openitcockpit.localhost:8443
        vm = (import ./dev/vm.nix { inherit self nixpkgs pkgs; }).config.system.build.vm;

        # Offline full stack test with pinned upstream images (large!).
        # Not part of `nix flake check`; see README.
        test-full-stack = import ./tests/full-stack.nix { inherit pkgs self; };
      });

      apps = forAllSystems (pkgs: {
        vm = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.vm}/bin/run-oitc-vm";
          meta.description = "Interactive NixOS VM running openITCOCKPIT";
        };
        update-test-images = {
          type = "app";
          program = "${pkgs.callPackage ./tests/update-images.nix { }}/bin/update-test-images";
          meta.description = "Re-pin the images used by test-full-stack";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            nixfmt
            nixd
            statix
            deadnix
            skopeo
            nix-prefetch-docker
            jq
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
