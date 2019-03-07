#!/usr/bin/env ruby
require "sequel"
require "pp"
require "linkeddata"
require "json"

@graph = RDF::Repository.load("merged.owl")
DB = Sequel.connect("postgres://localhost/cafe")

questionnaire = ARGV[0] unless ARGV.empty?
questionnaire ||= "center"

class Representation
  attr_reader :question, :option, :question_text
  def initialize(question_id, question_text)
    @question = question_id
    @question_text = question_text.scan(/([^{]+){([^|]+)|[^}]+}(.+)/).join
  end
end

class Instance
  attr_reader :rdfclass, :uri, :label

  def initialize(uri, rdfclass, graph)
    @uri = uri
    @rdfclass = rdfclass
    @label = find_label(rdfclass, graph)
  end
end

class Anon
  attr_reader :uri

  def initialize(uri)
    @uri = uri
  end
end

class Statement
  attr_reader :representation, :subject, :predicate, :object, :choice
  def initialize(rep, s, p, o, choice, graph)
    @representation = rep
    @subject = s
    @predicate = p
    # @p_label = find_label(p, graph)
    @object = o
    @choice = !choice.nil?
  end
end

def get_uri(shortened, qid)
  prefix, uri = shortened.split(":")
  return "#{@prefixes[prefix]}#{uri}" unless prefix == "_"
  "#{qid}/#{uri}"
end

def find_label(uri, graph)
  solution = RDF::Query.execute(graph) {
    pattern [RDF::URI.new(uri), RDF::RDFS.label, :name]
  }

  return solution.first[:name] unless solution.empty?
  uri
end

@prefixes = DB[:questionnaire_rdfprefix].as_hash(:short, :full)
@instances = {}
@statements = []

query = <<~SQL
  select subject, predicate, obj, question_id, text, choice_id
  from questionnaire_statement
    join questionnaire_question on question_id = questionnaire_question.id
    join questionnaire_category on category_id = questionnaire_category.id
  where questionnaire = '#{questionnaire}'
SQL

DB[query].to_hash_groups(:question_id).each do |question, statements|
  rep = Representation.new(question, statements.first[:text])
  statements.select {|s| s[:predicate] == "rdf:type" }.each do |instance|
    uri = get_uri(instance[:subject], question)
    rdfclass = get_uri(instance[:obj], question)
    @instances[uri] ||= Instance.new(uri, rdfclass, @graph)
  end
  statements.select {|s| s[:predicate] != "rdf:type" }.each do |statement|
    s = get_uri(statement[:subject], question)
    p = get_uri(statement[:predicate], question)
    o = get_uri(statement[:obj], question)
    si, oi = @instances.values_at(s, o)
    si ||= Anon.new(s)
    oi ||= Anon.new(o)
    @statements << Statement.new(rep, si, p, oi, statement[:choice_id], @graph)
  end
end

def find_or_create_node(i, nodes, rep)
  if (node = nodes.find {|n| n[:uri] == i.uri})
    node[:questions] |= [rep.question]
    node[:q_text] = rep.question_text
  else
    nodes << {uri: i.uri,
              type: "ANON",
              question: rep.question,
              questions: [rep.question],
              q_text: rep.question_text,}
  end
  i.uri
end

nodes = @instances.map {|k, v|
  {uri: k,
   type: "INSTANCE",
   label: v.label,
   questions: [],}
}
links = @statements.map {|s|
  {source: find_or_create_node(s.subject, nodes, s.representation),
   target: find_or_create_node(s.object, nodes, s.representation),
   type: s.choice ? "B" : "A",}
}
File.write("#{questionnaire}.json", JSON.generate({nodes: nodes, links: links}))
