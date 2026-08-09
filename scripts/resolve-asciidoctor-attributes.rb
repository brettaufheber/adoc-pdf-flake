#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'asciidoctor'

module Docgen
  module AttributeResolver
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
      require_path = BACKEND_REQUIRE_PATHS[backend]
      require require_path if require_path
      extra_requires.each { |library| require library }
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

      document.attributes.sort.to_h
    rescue StandardError => e
      abort %(Unable to evaluate AsciiDoc header in #{input_file.inspect}: #{e.class}: #{e.message})
    end
  end
end

options = {
  backend: 'html5',
  safe_mode: 'unsafe',
  attribute_entries: [],
  extra_requires: []
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: resolve-asciidoctor-attributes.rb [OPTIONS] INPUT_FILE'

  opts.on('-b', '--backend BACKEND', 'Backend used while evaluating the header (default: html5)') do |backend|
    options[:backend] = backend
  end

  opts.on('-S', '--safe-mode MODE', Docgen::AttributeResolver::SAFE_MODES.keys,
          'Safe mode: unsafe, safe, server, or secure (default: unsafe)') do |safe_mode|
    options[:safe_mode] = safe_mode
  end

  opts.on('-a', '--attribute ATTRIBUTE', 'Asciidoctor attribute entry; repeatable and order-preserving') do |attribute|
    options[:attribute_entries] << attribute
  end

  opts.on('-r', '--require LIBRARY', 'Additional Ruby library that registers a custom backend; repeatable') do |library|
    options[:extra_requires] << library
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

attributes = Docgen::AttributeResolver.resolve(
  input_file: input_file,
  backend: options[:backend],
  safe_mode: options[:safe_mode],
  attribute_entries: options[:attribute_entries],
  extra_requires: options[:extra_requires]
)

puts JSON.generate(attributes)
