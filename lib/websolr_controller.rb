require "uri"
require "rubygems"
require "restclient"
require 'rexml/document'
require "fileutils"
require "net/http"
include FileUtils

SOLR_PATH = "#{File.dirname(File.expand_path(__FILE__))}/../solr" unless defined? SOLR_PATH
SOLR_LOGS_PATH = "#{ENV["PWD"]}/log" unless defined? SOLR_LOGS_PATH
SOLR_PIDS_PATH = "#{ENV["PWD"]}/tmp/pids" unless defined? SOLR_PIDS_PATH
SOLR_DATA_PATH = "#{ENV["PWD"]}/solr/#{ENV['RAILS_ENV']}" unless defined? SOLR_DATA_PATH
SOLR_JVM_OPTIONS = ENV["JAVA_OPTIONS"] || "-Xmx256M"

mkdir_p SOLR_PATH
mkdir_p SOLR_LOGS_PATH
mkdir_p SOLR_PIDS_PATH
mkdir_p SOLR_DATA_PATH

class WebsolrController
  COMMANDS = %w[add list delete configure start stop]
  SOLR_PORT = 8983
  
  def initialize(parser)
    @options = parser.options
    @command = @options.delete(:command)
    @parser = parser
    @user = @options[:user] || ENV["WEBSOLR_USER"]
    @pass = @options[:pass] || ENV["WEBSOLR_PWD"]
    @base = "http://#{URI::escape @user}:#{URI::escape @pass}@websolr.com"
  end
  
  def die(s)
    STDERR.puts s
    exit(1)
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
  
  def check_local_solr_conditions
    ENV["RAILS_ENV"] = @options[:rails_env] || ENV["RAILS_ENV"] || "development"
    begin
      require "config/environment"
    rescue LoadError
      die("I can't find config/environment.rb.  Are we in a rails app?")
    end
    
    unless url = ENV["WEBSOLR_URL"]
      die("The WEBSOLR_URL environment variable is not set.\nHave you run websolr configure?")
    end
    uri = URI.parse(url)
    @port = uri.port
  rescue URI::InvalidURIError => e
    die(e.message)
  end
  
  def cmd_start
    check_local_solr_conditions    
    begin
      n = Net::HTTP.new('127.0.0.1', @port)
      n.request_head('/').value 
      
    rescue Net::HTTPServerException #responding
      puts "Port #{@port} in use" and return

    rescue Errno::ECONNREFUSED #not responding
      Dir.chdir(SOLR_PATH) do
        pid = fork do
          exec "java #{SOLR_JVM_OPTIONS} -Dsolr.data.dir=#{SOLR_DATA_PATH} -Djetty.logs=#{SOLR_LOGS_PATH} -Djetty.port=#{@port} -jar start.jar"
        end
        sleep(5)
        File.open("#{SOLR_PIDS_PATH}/#{ENV['RAILS_ENV']}_pid", "w"){ |f| f << pid}
        puts "#{ENV['RAILS_ENV']} Solr started successfully on #{SOLR_PORT}, pid: #{pid}."
      end
    end
  end
  
  def cmd_stop
    ENV["RAILS_ENV"] = @options[:rails_env] || ENV["RAILS_ENV"] || "development"
    fork do
      file_path = "#{SOLR_PIDS_PATH}/#{ENV['RAILS_ENV']}_pid"
      if File.exists?(file_path)
        File.open(file_path, "r") do |f| 
          pid = f.readline
          Process.kill('TERM', pid.to_i)
        end
        File.unlink(file_path)
        Rake::Task["solr:destroy_index"].invoke if ENV['RAILS_ENV'] == 'test'
        puts "Solr shutdown successfully."
      else
        puts "PID file not found at #{file_path}. Either Solr is not running or no PID file was written."
      end
    end
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
    required_options :name => "-n"
    doc = get "/slices.xml"
    found = false
    REXML::XPath.each(doc, "//slice") do |node|
      if x(node, 'name') == self.name
        found = true
        FileUtils.mkdir_p "config/initializers"
        path = "config/initializers/websolr.rb"
        puts "Writing #{path}"
        File.open(path, "w") do |f|
str = <<-STR
require 'websolr'
case RAILS_ENV
when 'production'
  ENV['WEBSOLR_URL'] ||= '#{x node, 'base-url'}'
else
  ENV['WEBSOLR_URL'] ||= 'http://localhost:8983'
end
STR
          f.puts str
        end
        
        FileUtils.mkdir_p "lib/tasks"
        path = "lib/tasks/websolr.rake"
        puts "Writing #{path}"
        File.open(path, "w") do |f|
          f.puts "require 'rubygems'\nrequire 'websolr_rails/tasks'"
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