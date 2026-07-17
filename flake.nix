{
  description = "Asciidoctor PDF generation tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs-asciidoctor.url = "github:NixOS/nixpkgs/nixos-25.05";
    kroki-src = {
      url = "github:asciidoctor/asciidoctor-kroki/92954d097896069974bb2becda2402a6b8fad3dd";
      flake = false;
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    nixpkgs-asciidoctor,
    kroki-src,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        asciidoctorPkgs = nixpkgs-asciidoctor.legacyPackages.${system};

        fontPackages = with pkgs; [
          bakoma_ttf
        ];

        features = {
          default = {
            packages = with pkgs; [
              coreutils
              findutils
              tzdata
              cacert
              bash
            ];
            env = {
              SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              # LANG = "en_US.UTF-8";  # to ignore language info of the system
              # LC_ALL = "en_US.UTF-8";  # to ignore language info of the system
              # TZ = "UTC";  # to ignore zone info of the system
            };
            shellHook = ''
              if [[ $- == *i* ]]; then
                bind '"\e[A": history-search-backward'
                bind '"\e[B": history-search-forward'
              fi
            '';
          };

          adocPdf = {
            packages = [
              (asciidoctorPkgs.asciidoctor-with-extensions.override {
                withJava = false;
              })
              pkgs.fontconfig
            ] ++ fontPackages;
            env = {
              FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = fontPackages; };
              RUBYLIB = "${kroki-src.outPath}/ruby/lib";  # make Kroki available
              RUBYOPT = "-W0";  # suppress warnings
            };
          };
        };

        adocPdfApp =
          let
            scriptSource = builtins.readFile ./scripts/adoc-pdf.sh;

            isLeadingMetadataLine = line:
              builtins.match "^[[:space:]]*$" line != null
              || builtins.match "^[[:space:]]*#.*$" line != null
              || builtins.match "^[[:space:]]*set([[:space:]].*)?$" line != null;

            dropWhile = predicate: list:
              if list == [ ] then
                [ ]
              else if predicate (builtins.head list) then
                dropWhile predicate (builtins.tail list)
              else
                list;

            scriptBody =
              pkgs.lib.concatStringsSep "\n" (
                dropWhile isLeadingMetadataLine (
                  pkgs.lib.splitString "\n" scriptSource
                )
              );
          in
          pkgs.writeShellApplication {
            name = "adoc-pdf";
            runtimeInputs = features.default.packages ++ features.adocPdf.packages;
            runtimeEnv = features.default.env // features.adocPdf.env;

            text = scriptBody;
          };
    in
    {
      packages.default = adocPdfApp;
      apps.default = flake-utils.lib.mkApp { drv = adocPdfApp; };

      devShells.default = pkgs.mkShell (
        features.default.env // features.adocPdf.env // {
          packages = features.default.packages ++ features.adocPdf.packages;
          shellHook = features.default.shellHook;
        }
      );
    }
  );
}
