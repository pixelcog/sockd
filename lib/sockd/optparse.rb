require "fileutils"
require "optparse"
require "shellwords"
require "sockd/errors"

module Sockd
  class OptionParser

    attr_accessor :name, :options, :callback

    def initialize(name = nil, defaults = {}, &block)
      @name = name || File.basename($0)
      @options = defaults.replace({
        host:      "127.0.0.1",
        port:      0,
        socket:    false,
        daemonize: true,
        pid_path:  "/var/run/#{safe_name}.pid",
        log_path:  false,
        force:     false,
        user:      nil,
        group:     nil
      }.merge(defaults))
      @callback = block if block_given?
    end

    def safe_name
      name.gsub(/(^[0-9]*|[^0-9a-z])/i, '')
    end

    def parser
      @parser ||= ::OptionParser.new do |opts|
        opts.summary_width = 25
        opts.banner = <<-EOF.gsub /^[ ]{8}/, ''
        Usage: #{name} [options] <command> [<message>]

        Commands:
            #{name}                 run server without forking
            #{name} start           start as a daemon
            #{name} stop [-f]       stop a running daemon
            #{name} restart         stop, then start the daemon
            #{name} send <message>  send a message to a running daemon
            #{name} <message>       send a message (send command implied)

        Options:
        EOF

        instance_exec(opts, callback) if callback

        opts.on("-p", "--port PORT", String, "Listen on TCP port PORT (default: #{options[:port]})") do |x|
          options[:port] = x
          # prefer TCP connection if explicitly setting a port
          options[:socket] = nil
        end

        opts.on("-H", "--host HOST", String, "Listen on HOST (default: #{options[:host]})") do |x|
          options[:host] = x
          # prefer TCP connection if explicitly setting a host
          options[:socket] = nil
        end

        opts.on("-s", "--socket SOCKET", String, "Listen on Unix socket path (disables network support)", "(default: #{options[:socket]})") do |x|
          options[:socket] = File.expand_path(x)
        end

        opts.on("-P", "--pid FILE", String, "Where to write the PID file", "(default: #{options[:pid_path]})") do |x|
          options[:pid_path] = File.expand_path(x)
        end

        opts.on("-l", "--log FILE", String, "Where to write the log file", "(default: #{options[:log_path]})") do |x|
          options[:log_path] = File.expand_path(x)
        end

        opts.on("-u", "--user USER", String, "Assume the identity of USER when running as a daemon", "(default: #{options[:user]})") do |x|
          options[:user] = x
        end

        opts.on("-g", "--group GROUP", String, "Assume group GROUP when running as a daemon", "(default: #{options[:group]})") do |x|
          options[:group] = x
        end

        opts.on("-f", "--force", String, "Force kill if SIGTERM fails when running 'stop' command") do
          options[:force] = true
        end

        opts.separator "\n  Additional Options:"

        opts.on_tail("-h", "--help", "Display this usage information.") do
          puts "\n#{opts}\n"
          exit
        end
      end
    end

    def parse!(argv = nil)
      argv ||= ARGV.dup
      argv = Shellwords.shellwords argv if argv.is_a? String

      parser.parse! argv

      if argv.empty?
        argv.push 'start'
        options[:daemonize] = false
      end
      argv.unshift 'send' unless %w(start stop restart send).include?(argv.first)

      argv
    rescue ::OptionParser::InvalidOption, ::OptionParser::MissingArgument => e
      raise OptionParserError.new e
    end

    def to_s
      parser.to_s
    end
  end
end
