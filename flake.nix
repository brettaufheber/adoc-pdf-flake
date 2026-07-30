{
  description = "Reproducible Asciidoctor PDF generation tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        readShellApplicationBody = path: let
          isLeadingMetadataLine = line:
            builtins.match "^[[:space:]]*$" line != null
            || builtins.match "^[[:space:]]*#.*$" line != null
            || builtins.match "^[[:space:]]*set([[:space:]].*)?$" line != null;

          dropWhile = predicate: list:
            if list == []
            then []
            else if predicate (builtins.head list)
            then dropWhile predicate (builtins.tail list)
            else list;
        in
          /*
          writeShellApplication already adds a shebang and strict mode.
          Remove those leading lines from the original script.
          */
          lib.concatStringsSep "\n" (
            dropWhile isLeadingMetadataLine (
              lib.splitString "\n" (
                builtins.readFile path
              )
            )
          );

        fontPackages = with pkgs; [
          # Computer Modern and traditional TeX fonts
          bakoma_ttf
          cm_unicode
          lmodern
          tex-gyre
          # Scientific text and mathematical symbols
          libertinus
          stix-two
          # Broad Unicode coverage
          noto-fonts
          noto-fonts-color-emoji
          noto-fonts-cjk-sans
          noto-fonts-cjk-serif
          # Common document and browser fonts
          dejavu_fonts
          liberation_ttf
          roboto
          inter
          # Coherent serif, sans and monospace families
          ibm-plex
          # Source code
          source-code-pro
          fira-code
        ]
        ++ lib.attrValues tex-gyre;

        /*
        Asciidoctor PDF does not resolve a font family through Fontconfig.
        Fonts used in a PDF theme must be declared by filename in the
        font catalog.
        */
        pdfFontDirectory =
          pkgs.runCommand "asciidoctor-pdf-fonts" {
            nativeBuildInputs = with pkgs; [
              coreutils
              findutils
            ];
          } ''
            ${pkgs.bash}/bin/bash \
              ${./scripts/create-font-directory.sh} \
              "$out" \
              ${lib.escapeShellArgs (map toString fontPackages)}
          '';

        features = {
          common = {
            packages = with pkgs; [
              coreutils
              findutils
              util-linux
              watchexec
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

          tools = {
            packages = with pkgs; [
              fontconfig
              graphicsmagick
            ];
            env = {
              FONTCONFIG_FILE = pkgs.makeFontsConf {fontDirectories = fontPackages;};
              ASCIIDOCTOR_PDF_FONTS_DIR = "${pdfFontDirectory}";
              RUBYOPT = "-W0"; # suppress Ruby deprecation noise, not Asciidoctor log messages
            };
          };

          build = {
            packages = with pkgs; [
              bundix
              bundler
              git
              ruby
            ];
            env = {
              BUNDLE_FORCE_RUBY_PLATFORM = "true";
            };
          };

          development = {
            packages = with pkgs; [
              man-db
              shellcheck
            ];
            env = {};
          };
        };

        asciidoctorToolchain = pkgs.callPackage ./nix/asciidoctor-toolchain.nix {};

        adocPdfApp = pkgs.writeShellApplication {
          name = "adoc-pdf";
          runtimeInputs =
            features.common.packages
            ++ features.tools.packages
            ++ [
              asciidoctorToolchain
            ];
          runtimeEnv = features.common.env // features.tools.env;
          inheritPath = false;
          text = readShellApplicationBody ./scripts/adoc-pdf.sh;
        };

        updateGemsApp = pkgs.writeShellApplication {
          name = "update-gems";
          runtimeInputs =
            features.common.packages
            ++ features.build.packages;
          runtimeEnv = features.common.env // features.build.env;
          inheritPath = false;
          text = readShellApplicationBody ./scripts/update-gems.sh;
        };
      in {
        packages = let
          individualPackages = {
            adoc-pdf = adocPdfApp;
            asciidoctor-toolchain = asciidoctorToolchain;
            fonts = pdfFontDirectory;
            update-gems = updateGemsApp;
          };
        in
          individualPackages
          // {
            default = pkgs.linkFarm "all" (
              lib.mapAttrsToList (
                name: path: {
                  inherit name path;
                }
              )
              individualPackages
            );
          };

        apps =
          lib.genAttrs
          asciidoctorToolchain.exes
          (
            exe:
              flake-utils.lib.mkApp {
                drv = asciidoctorToolchain;
                name = exe;
              }
          )
          // {
            default = flake-utils.lib.mkApp {drv = adocPdfApp;};
            adoc-pdf = flake-utils.lib.mkApp {drv = adocPdfApp;};
            update-gems = flake-utils.lib.mkApp {drv = updateGemsApp;};
          };

        devShells = {
          default = pkgs.mkShell (
            features.common.env
            // features.tools.env
            // features.development.env
            // {
              packages =
                features.common.packages
                ++ features.tools.packages
                ++ features.development.packages
                ++ [
                  adocPdfApp
                  asciidoctorToolchain
                ];
              shellHook = features.common.shellHook;
            }
          );

          build = pkgs.mkShell (
            features.common.env
            // features.build.env
            // features.development.env
            // {
              packages =
                features.common.packages
                ++ features.build.packages
                ++ features.development.packages
                ++ [
                  updateGemsApp
                ];
              shellHook = features.common.shellHook;
            }
          );
        };

        formatter = pkgs.alejandra;
      }
    );
}
