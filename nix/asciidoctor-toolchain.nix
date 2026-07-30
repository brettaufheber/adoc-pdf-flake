{
  bundlerApp,
}:
  bundlerApp {
    pname = "asciidoctor";
    gemdir = ./asciidoctor;
    exes = [
      "asciidoctor"
      "asciidoctor-pdf"
      "asciidoctor-epub3"
      "asciidoctor-multipage"
      "asciidoctor-reducer"
      "asciidoctor-revealjs"
    ];
    meta = {
      description = "Reproducible Asciidoctor converter toolchain";
      mainProgram = "asciidoctor";
    };
  }
