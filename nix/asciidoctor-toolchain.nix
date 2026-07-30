{
  bundlerApp,
  defaultGemConfig,
}: let
  exes = [
    "asciidoctor"
    "asciidoctor-epub3"
    "asciidoctor-multipage"
    "asciidoctor-pdf"
    "asciidoctor-reducer"
    "asciidoctor-revealjs"
  ];

  gemConfig =
    defaultGemConfig
    // {
      mathematical = attrs: let
        defaults = defaultGemConfig.mathematical attrs;
      in
        defaults
        // {
          env =
            (defaults.env or {})
            // {
              CMAKE_POLICY_VERSION_MINIMUM = "3.5";
            };
        };
    };
in
  bundlerApp {
    pname = "asciidoctor";
    gemdir = ./asciidoctor;
    inherit exes gemConfig;
    passthru = {inherit exes;};
    meta = {
      description = "Reproducible Asciidoctor converter toolchain";
      mainProgram = "asciidoctor";
    };
  }
