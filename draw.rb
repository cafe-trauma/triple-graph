#!/usr/bin/env ruby
require 'sequel'
require 'pp'
require 'linkeddata'
require 'json'

@graph = RDF::Repository.load('merged.owl')
DB = Sequel.connect('postgres://localhost/cafe')

def find_label(uri, graph)
  solution = RDF::Query.execute(graph) do
    pattern [RDF::URI.new(uri), RDF::RDFS.label, :name]
  end

  return solution.first[:name] unless solution.empty?
  return uri
end

class Representation
  attr_reader :question, :option
  def initialize(question_id)
    @question = question_id
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
    %Q("#{@uri}" [shape=box, label="#{@uri}\\n#{@label}"])
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
  attr_reader :representation, :subject, :predicate, :object
  def initialize(rep, s, p, o, graph)
    @representation = rep
    @subject = s
    @predicate = p
    @p_label = find_label(p, graph)
    @object = o
  end

  def print
    %Q("#{@subject.print}" -> "#{@object.print}" [label="#{@p_label}"])
  end
end


@prefixes = DB[:questionnaire_rdfprefix].as_hash(:short, :full)

def get_uri(shortened, qid)
  prefix, uri = shortened.split(':')
  return "#{@prefixes[prefix]}#{uri}" unless prefix == '_'
  return "#{qid}/#{uri}"
end

representations = []
@instances = {}
@statements = []

query = <<SQL
select subject, predicate, obj, question_id from questionnaire_statement
join questionnaire_question on question_id = questionnaire_question.id
join questionnaire_category on category_id = questionnaire_category.id
where questionnaire = 'system'
SQL

db_statements = DB[query].to_hash_groups(:question_id)
db_statements.each do |question, statements|
  #next unless ARGV.include?(question.to_s)
  rep = Representation.new(question)
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
    @statements << Statement.new(rep, si, p, oi, @graph)
  end
end

dot = <<EOS
digraph g {
#{@instances.values.map{|i| i.print_box}.join("\n")}
node [shape=diamond]
graph [splines=true, nodesep=.5, ranksep=0, overlap=false]
#{@statements.map{|s| s.print}.join("\n")}
}
EOS

File.write("graph.dot", dot)

json = {}
json["nodes"] = []
json["links"] = []
@instances.each do |k, v|
  json["nodes"] << {:uri => k, :type => "INSTANCE", :label => v.label}
end
@statements.each do |s|
  json["links"] << {:source => s.subject.print, :target => s.object.print, :type => "A"}
  json["nodes"] << {:uri => s.subject.print, :type => "ANON", :label => s.subject.print} if s.subject.is_a?(Anon)
  json["nodes"] << {:uri => s.object.print, :type => "ANON", :label => s.object.print} if s.object.is_a?(Anon)
end
File.write("system.json", JSON.generate(json))
