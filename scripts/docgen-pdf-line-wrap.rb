# frozen_string_literal: true

require 'asciidoctor-pdf'

module Docgen
  module NoBreakOnHyphenConverter
    def init_pdf(document)
      result = super

      @docgen_no_break_on_hyphen =
        document.attr? 'docgen-no-break-on-hyphen'

      result
    end

    def docgen_no_break_on_hyphen?
      @docgen_no_break_on_hyphen == true
    end
  end

  module NoBreakOnHyphenLineWrap
    private

    def docgen_no_break_on_hyphen?
      @document.respond_to?(:docgen_no_break_on_hyphen?) &&
        @document.docgen_no_break_on_hyphen?
    end

    def break_chars(encoding = ::Encoding::UTF_8)
      return super unless docgen_no_break_on_hyphen?

      [
        whitespace(encoding),
        soft_hyphen(encoding),
      ].join('')
    end

    def scan_pattern(encoding = ::Encoding::UTF_8)
      return super unless docgen_no_break_on_hyphen?

      ebc = break_chars(encoding)
      eshy = soft_hyphen(encoding)
      ews = whitespace(encoding)

      patterns = [
        "[^#{ebc}]+#{eshy}",
        "[^#{ebc}]+",
        "[#{ews}]+",
        eshy.to_s,
      ]

      Regexp.new(
        patterns
          .map { |pattern| pattern.encode(encoding) }
          .join('|')
      )
    end

    def word_division_scan_pattern(encoding = ::Encoding::UTF_8)
      return super unless docgen_no_break_on_hyphen?

      common_whitespaces = [
        "\t",
        "\n",
        "\v",
        "\r",
        ' ',
      ].map do |char|
        char.encode(encoding)
      end

      Regexp.union(
        common_whitespaces +
          [
            zero_width_space(encoding),
            soft_hyphen(encoding),
          ].compact
      )
    end
  end
end

Asciidoctor::PDF::Converter.prepend(
  Docgen::NoBreakOnHyphenConverter
)

Prawn::Text::Formatted::LineWrap.prepend(
  Docgen::NoBreakOnHyphenLineWrap
)
