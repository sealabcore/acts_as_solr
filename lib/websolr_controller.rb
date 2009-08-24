require "uri"
require "rubygems"
require "restclient"
require 'rexml/document'
require "fileutils"

class WebsolrController
  COMMANDS = %w[add list delete configure]
  
  def initialize(parser)
    @options = parser.options
    @command = @options.delete(:command)
    @parser = parser
    @user = @options[:user] || ENV["WEBSOLR_USER"]
    @pass = @options[:pass] || ENV["WEBSOLR_PWD"]
    @base = "http://#{URI::escape @user}:#{URI::escape @pass}@websolr.com"
  end
  
  def required_options(hash)
    hash.inject(true) do |memo, (key, flag)|
      unless @options[key]
        STDERR.puts "Please use the #{flag} flag to specify the #{key}."
      end
      memo && @options[key]
    end || exit(1)
  end
  
  def url(url)
    URI.join(@base, url).to_s
  end
  
  def cmd_add
    required_options :name => "-n"
    doc = post "/slices.xml", {:slice => {:name => name}}
    puts "#{x doc, '//name'}\t#{x doc, '//base-url'}"
  end
  
  def cmd_delete
    required_options :name => "-n"
    delete "/slices/#{name}/destroy"
    puts "done"
  end
  
  def x(doc, path)
    REXML::XPath.first(doc, path).text 
  end
  
  def cmd_list
    doc = get "/slices.xml"
    REXML::XPath.each(doc, "//slice") do |node|
      puts "#{x node, 'name'}\t#{x node, 'base-url'}"
    end
  end
  
  %w[get post delete put].each do |verb|
    eval <<-STR
      def #{verb}(url, params = {})
        str = RestClient.#{verb} url(url), params
        return nil if str.strip == ""
        REXML::Document.new(StringIO.new str)
      rescue RestClient::RequestFailed => e
        print_errors REXML::Document.new(StringIO.new e.response.body)
      end
    STR
  end
    
  def print_errors(doc)
    REXML::XPath.each(doc, "//error") do |node|
      STDERR.puts "Error: #{node.text}"
    end
    exit 1
  end
  
  def cmd_configure
    required_options :name => "-n", :rails_env => "-e"
    doc = get "/slices.xml"
    found = false
    REXML::XPath.each(doc, "//slice") do |node|
      if x(node, 'name') == self.name
        found = true
        FileUtils.mkdir_p "config/initializers"
        path = "config/initializers/websolr_#{rails_env}.rb"
        puts "Writing #{path}"
        File.open(path, "w") do |f|
          f.puts "ENV['WEBSOLR_URL'] ||= '#{x node, 'base-url'}'"
        end
      end
    end
    unless found
      STDERR.puts "Error: Index not found"
      exit 1
    end
  end
  
  def start
    if @user || @pass
      if(COMMANDS.include?(@command))
        send("cmd_#{@command}")
      else
        puts @parser
        exit(1)
      end
    else
      puts <<-STR
      
    You need to specify your username and password, either on the command
    line with the -u and -p flags, or in the WEBSOLR_USER and WEBSOLR_PWD
    environment variables.
    
      STR
      exit(1)
    end
  end
  
  def method_missing(method, *a, &b)
    return @options[method] if @options[method]
    super(method, *a, &b)
  end
end