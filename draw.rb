#!/usr/bin/env ruby
require "sequel"
require "pp"
require "linkeddata"
require "json"

@graph = RDF::Repository.load("merged.owl")
DB = Sequel.connect("postgres://localhost/cafe")

questionnaire = ARGV[0] unless ARGV.empty?
questionnaire ||= "center"

def find_label(uri, graph)
  solution = RDF::Query.execute(graph) {
    pattern [RDF::URI.new(uri), RDF::RDFS.label, :name]
  }

  return solution.first[:name] unless solution.empty?
  uri
end

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

  def print
    @uri
  end

  def print_box
    %("#{@uri}" [shape=box, label="#{@uri}\\n#{@label}"])
  end
end

class Anon
  attr_reader :uri

  def initialize(uri)
    @uri = uri
  end

  def print
    @uri
  end
end

class Statement
  attr_reader :representation, :subject, :predicate, :object, :choice
  def initialize(rep, s, p, o, choice, graph)
    @representation = rep
    @subject = s
    @predicate = p
    @p_label = find_label(p, graph)
    @object = o
    @choice = !choice.nil?
  end

  def print
    %("#{@subject.print}" -> "#{@object.print}" [label="#{@p_label}"])
  end
end

@prefixes = DB[:questionnaire_rdfprefix].as_hash(:short, :full)

def get_uri(shortened, qid)
  prefix, uri = shortened.split(":")
  return "#{@prefixes[prefix]}#{uri}" unless prefix == "_"
  "#{qid}/#{uri}"
end

@instances = {}
@statements = []

query = <<~SQL
  select subject, predicate, obj, question_id, text, choice_id from questionnaire_statement
  join questionnaire_question on question_id = questionnaire_question.id
  join questionnaire_category on category_id = questionnaire_category.id
  where questionnaire = '#{questionnaire}'
SQL

db_statements = DB[query].to_hash_groups(:question_id)
db_statements.each do |question, statements|
  # next unless ARGV.include?(question.to_s)
  rep = Representation.new(question, statements.first[:text])
  statements.select {|s| s[:predicate] == "rdf:type" }.each do |instance|
    uri = get_uri(instance[:subject], question)
    rdfclass = get_uri(instance[:obj], question)
    @instances[uri] = Instance.new(uri, rdfclass, @graph)
  end
  statements.select {|s| s[:predicate] != "rdf:type" }.each do |statement|
    s = get_uri(statement[:subject], question)
    p = get_uri(statement[:predicate], question)
    o = get_uri(statement[:obj], question)
    si = @instances[s]
    si ||= Anon.new(s)
    oi = @instances[o]
    oi ||= Anon.new(o)
    @statements << Statement.new(rep, si, p, oi, statement[:choice_id], @graph)
  end
end

dot = <<~EOS
  digraph g {
    #{@instances.values.map {|i| i.print_box}.join("\n")}
    node [shape=diamond]
    graph [splines=true, nodesep=.5, ranksep=0, overlap=false]
    #{@statements.map {|s| s.print}.join("\n")}
  }
EOS

File.write("#{questionnaire}.dot", dot)

def find_or_create_node(i, nodes, rep)
  if (node = nodes.find {|n| n[:uri] == i.uri})
    node[:questions] << rep.question unless node[:questions].include?(rep.question)
  else
    nodes << {uri: i.uri,
              type: "ANON",
              question: rep.question,
              questions: [rep.question],
              q_text: rep.question_text,}
  end
  i.uri
end

json = {}
json["nodes"] = []
json["links"] = []
@instances.each do |k, v|
  json["nodes"] << {uri: k,
                    type: "INSTANCE",
                    label: v.label,
                    questions: [],}
end
@statements.each do |s|
  json["links"] << {source: find_or_create_node(s.subject, json["nodes"], s.representation),
                    target: find_or_create_node(s.object, json["nodes"], s.representation),
                    type: s.choice ? "B" : "A",}
end
File.write("#{questionnaire}.json", JSON.generate(json))
