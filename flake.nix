{
  description = "Development environment for the Quarto blog";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      supportedSystems =
        [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forEachSupportedSystem = f:
        nixpkgs.lib.genAttrs supportedSystems
        (system: f { pkgs = import nixpkgs { inherit system; }; });
    in {
      devShells = forEachSupportedSystem ({ pkgs }: {
        default =
          let
            # Quarto 1.10 requires Pandoc 3.10, but nixpkgs currently replaces
            # it with Pandoc 3.7. Keep the Pandoc binary bundled by Quarto.
            quartoPandoc = pkgs.stdenvNoCC.mkDerivation {
              pname = "quarto-pandoc";
              inherit (pkgs.quarto) version src;
              sourceRoot =
                if pkgs.stdenv.hostPlatform.isDarwin then "."
                else "quarto-${pkgs.quarto.version}";
              installPhase = ''
                runHook preInstall
                mkdir -p $out/bin
                cp bin/tools/${pkgs.stdenv.hostPlatform.parsed.cpu.name}/pandoc \
                  $out/bin/pandoc
                runHook postInstall
              '';
              meta.mainProgram = "pandoc";
            };
            quarto = pkgs.quarto.override { pandoc = quartoPandoc; };
          in pkgs.mkShell {
            packages = [ quarto pkgs.markdownlint-cli ];
          };
      });
    };
}
