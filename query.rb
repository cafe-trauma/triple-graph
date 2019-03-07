#!/usr/bin/env ruby
require "sequel"
require "linkeddata"

@graph = RDF::Repository.load("oostt.owl")

def find_label(uri)
  solution = RDF::Query.execute(@graph) {
    pattern [RDF::URI.new(uri), RDF::RDFS.label, :label]
  }

  return solution.first[:label] unless solution.empty?
  uri
end

puts find_label("http://purl.obolibrary.org/obo/OOSTT_00000111")
