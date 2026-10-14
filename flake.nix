{
  description = "Development environment for the Quarto blog";

  inputs = {
    # 26.11 dropped Intel macOS; 26.05 supports both Intel and Apple Silicon.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    # Newer Nixpkgs Quarto packages fail to render this site with an
    # "Unknown option syntax-highlighting" Pandoc error.
    quartoNixpkgs.url =
      "github:NixOS/nixpkgs/88d3861acdd3d2f0e361767018218e51810df8a1";
  };

  outputs = { self, nixpkgs, quartoNixpkgs }:
    let
      supportedSystems =
        [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSupportedSystem = f:
        nixpkgs.lib.genAttrs supportedSystems
        (system:
          f {
            pkgs = import nixpkgs { inherit system; };
            quartoPkgs = import quartoNixpkgs { inherit system; };
          });
    in {
      devShells = forEachSupportedSystem ({ pkgs, quartoPkgs }: {
        default = pkgs.mkShell {
          packages = [ quartoPkgs.quarto pkgs.markdownlint-cli ];
        };
      });
    };
}
