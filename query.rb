#!/usr/bin/env ruby
require 'sequel'
require 'linkeddata'
include RDF

@graph = RDF::Repository.load('oostt.owl')

def find_label(uri)
  solution = RDF::Query.execute(@graph) do
    pattern [RDF::URI.new(uri), RDFS.label, :label]
  end

  return solution.first[:label] unless solution.empty?
  return uri
end

puts find_label("http://purl.obolibrary.org/obo/OOSTT_00000111")
