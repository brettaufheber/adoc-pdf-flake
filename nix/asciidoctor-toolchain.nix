{
  bundlerApp,
}:
  let
    exes = [
      "asciidoctor"
      "asciidoctor-pdf"
      "asciidoctor-epub3"
      "asciidoctor-multipage"
      "asciidoctor-reducer"
      "asciidoctor-revealjs"
    ];
  in
  bundlerApp {
    pname = "asciidoctor";
    gemdir = ./asciidoctor;
    inherit exes;
    passthru = { inherit exes; };
    meta = {
      description = "Reproducible Asciidoctor converter toolchain";
      mainProgram = "asciidoctor";
    };
  }
