{
lib
}: let
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
in {
  readShellApplicationBody = path:
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
}
