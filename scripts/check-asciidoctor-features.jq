def normalized_stem_format:
  if has("stem") then
    (.stem | tostring | ascii_downcase | gsub("^\\s+|\\s+$"; ""))
    | if . == "" then "asciimath" else . end
  else
    null
  end;

def bibtex_enabled: (
  has("docgen-use-bibtex") or any(keys[]; startswith("bibtex-"))
);

def mathematical_enabled: (
  has("docgen-use-mathematical") or (
    normalized_stem_format as $stem
    | $stem == "asciimath" or $stem == "latexmath"
  )
);

def kroki_enabled: (
  has("docgen-use-kroki") or any(keys[]; startswith("kroki-"))
);

{
  bibtex: bibtex_enabled,
  mathematical: mathematical_enabled,
  kroki: kroki_enabled
}
