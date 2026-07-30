#!/usr/bin/env ruby

require "digest"
require "json"
require "optparse"
require "yaml"

options = {
  project: File.expand_path("../project.yml", __dir__)
}

OptionParser.new do |parser|
  parser.on("--project PATH") { |value| options[:project] = File.expand_path(value) }
end.parse!

def deep_sort(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) do |key, result|
      result[key] = deep_sort(value[key])
    end
  when Array
    value.map { |item| deep_sort(item) }
  else
    value
  end
end

project_path = options.fetch(:project)
source = File.binread(project_path)
project = YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: true)

unless project.is_a?(Hash)
  warn "project specification must decode to an object"
  exit 1
end

payload = {
  "schemaVersion" => 1,
  "source" => File.basename(project_path),
  "sourceSha256" => Digest::SHA256.hexdigest(source),
  "project" => deep_sort(project)
}

puts JSON.pretty_generate(payload)
