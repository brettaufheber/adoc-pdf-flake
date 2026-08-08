#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'asciidoctor'

module Docgen
  module FeatureResolver
    FEATURE_NAMES = %w[mathematical bibtex kroki].freeze
    MATHEMATICAL_STEM_FORMATS = %w[asciimath latexmath].freeze

    # Asciidoctor Core already registers html5, docbook5, and manpage.
    # External converters are required only when their backend is selected, as
    # some converter gems also install global extensions or monkey patches.
    BACKEND_REQUIRE_PATHS = {
      'pdf' => 'asciidoctor-pdf',
      'epub3' => 'asciidoctor-epub3',
      'html5s' => 'asciidoctor-html5s',
      'multipage_html5' => 'asciidoctor-multipage',
      'reveal.js' => 'asciidoctor-revealjs',
      'revealjs' => 'asciidoctor-revealjs'
    }.freeze

    SAFE_MODES = {
      'unsafe' => :unsafe,
      'safe' => :safe,
      'server' => :server,
      'secure' => :secure
    }.freeze

    module_function

    def load_backend(backend, extra_requires)
      extra_requires.each { |library| require library }

      require_path = BACKEND_REQUIRE_PATHS[backend]
      require require_path if require_path
    rescue LoadError => e
      abort %(Unable to load Ruby library #{e.path.inspect} for backend #{backend.inspect}: #{e.message})
    end

    def resolve(input_file:, backend:, safe_mode:, attribute_entries:, extra_requires:)
      load_backend backend, extra_requires

      document = Asciidoctor.load_file(
        input_file,
        backend: backend,
        safe: SAFE_MODES.fetch(safe_mode),
        parse_header_only: true,
        attributes: attribute_entries
      )

      {
        'backend' => document.backend,
        'safe_mode' => document.attr('safe-mode-name') || safe_mode,
        'features' => {
          'mathematical' => detect_mathematical(document),
          'bibtex' => detect_prefixed_feature(document, 'bibtex'),
          'kroki' => detect_prefixed_feature(document, 'kroki')
        },
        'attributes' => document.attributes.sort.to_h
      }
    rescue StandardError => e
      abort %(Unable to evaluate AsciiDoc header in #{input_file.inspect}: #{e.class}: #{e.message})
    end

    def detect_mathematical(document)
      explicit_attribute = 'docgen-use-mathematical'
      explicit = document.attr? explicit_attribute

      stem_set = document.attr? 'stem'
      stem_format = normalize_stem_format(document.attr('stem')) if stem_set
      supported_stem = stem_set && MATHEMATICAL_STEM_FORMATS.include?(stem_format)

      reasons = []
      reasons << %(attribute:#{explicit_attribute}) if explicit
      reasons << %(stem=#{stem_format}) if supported_stem

      {
        'enabled' => explicit || supported_stem,
        'reasons' => reasons,
        'stem_format' => stem_format,
        'supported_stem_formats' => MATHEMATICAL_STEM_FORMATS
      }
    end

    def normalize_stem_format(value)
      normalized = value.to_s.strip.downcase
      # In AsciiDoc, an empty stem value has the effective value "asciimath".
      normalized.empty? ? 'asciimath' : normalized
    end

    def detect_prefixed_feature(document, feature_name)
      explicit_attribute = %(docgen-use-#{feature_name})
      explicit = document.attr? explicit_attribute
      prefix = %(#{feature_name}-)
      matched_attributes = document.attributes.keys
        .grep_v(/^docgen-/)
        .select { |name| name.start_with? prefix }
        .sort

      reasons = []
      reasons << %(attribute:#{explicit_attribute}) if explicit
      reasons.concat matched_attributes.map { |name| %(attribute:#{name}) }

      {
        'enabled' => explicit || !matched_attributes.empty?,
        'reasons' => reasons,
        'matched_attributes' => matched_attributes
      }
    end

    def shell_output(result)
      features = result.fetch('features')
      FEATURE_NAMES.map do |name|
        variable = %(DOCGEN_USE_#{name.upcase})
        value = features.fetch(name).fetch('enabled') ? 1 : 0
        %(#{variable}=#{value})
      end.join("\n")
    end
  end
end

options = {
  backend: 'html5',
  safe_mode: 'unsafe',
  attribute_entries: [],
  extra_requires: [],
  include_attributes: false,
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: resolve-asciidoctor-features.rb [OPTIONS] INPUT_FILE'

  opts.on('-b', '--backend BACKEND', 'Backend used while evaluating the header (default: html5)') do |backend|
    options[:backend] = backend
  end

  opts.on('-S', '--safe-mode MODE', Docgen::FeatureResolver::SAFE_MODES.keys,
          'Safe mode: unsafe, safe, server, or secure (default: unsafe)') do |safe_mode|
    options[:safe_mode] = safe_mode
  end

  opts.on('-a', '--attribute ATTRIBUTE', 'Asciidoctor attribute entry; repeatable and order-preserving') do |attribute|
    options[:attribute_entries] << attribute
  end

  opts.on('-r', '--require LIBRARY', 'Additional Ruby library that registers a custom backend; repeatable') do |library|
    options[:extra_requires] << library
  end

  opts.on('--include-attributes', 'Include all resolved header attributes in JSON output') do
    options[:include_attributes] = true
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end

begin
  parser.parse!(ARGV)
rescue OptionParser::ParseError => e
  warn e.message
  warn parser
  exit 2
end

if ARGV.length != 1
  warn 'Exactly one INPUT_FILE must be specified.'
  warn parser
  exit 2
end

input_file = File.expand_path(ARGV.first)
unless File.file?(input_file) && File.readable?(input_file)
  abort %(Input file does not exist or is not readable: #{input_file})
end

result = Docgen::FeatureResolver.resolve(
  input_file: input_file,
  backend: options[:backend],
  safe_mode: options[:safe_mode],
  attribute_entries: options[:attribute_entries],
  extra_requires: options[:extra_requires]
)

result.delete('attributes') unless options[:include_attributes]

puts(JSON.generate(result))
