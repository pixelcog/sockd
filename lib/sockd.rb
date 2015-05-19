require "yaml"
require "optparse"
require "sockd/runner"
require "sockd/version"

module Sockd

  class ParseError < OptionParser::ParseError; end
  class ConfigFileError < RuntimeError; end

  class << self

    def define(name = nil, options = {}, &block)
      Runner.define(name = nil, options, &block)
    end

    alias new define

    def run(name = nil, options = {}, &block)
      parse define(name, options, &block)
    end

    def parse(runner, argv = ARGV, &block)
      raise ArgumentError, 'You must provide an instance of Sockd::Runner' unless runner.class <= Runner
      options = {}
      parser = optparser(runner.name, options, &block)
      command, *message = parser.parse(argv)

      if options[:config_save]
        save_path = options[:config_path] || runner.options[:config_path]
        raise ParseError, 'no config file path specified, unable to save' unless save_path
        save_yaml options, save_path

        puts "config saved to: #{save_path}"
        exit
      end

      if options[:config_path]
        read_yaml options, options[:config_path]
      elsif runner.options[:config_path] && File.file?(runner.options[:config_path])
        read_yaml options, runner.options[:config_path]
      end

      runner.options.merge! options

      case command
      when nil
        runner.options[:daemonize] = false
        runner.start
      when 'start', 'stop', 'restart'
        raise ParseError, "invalid arguments for #{command}" unless message.empty?
        runner.public_send command.to_sym
      else
        message.unshift command unless command == 'send'
        raise ParseError, 'no message provided' if message.empty?
        puts runner.send message.join(' ')
      end
    rescue OptionParser::ParseError => e
      puts "Error: #{e.message}"
      puts parser
      puts ''
      exit 1
    rescue ConfigFileError, Runner::ServiceError => e
      puts "Error: #{e.message}"
      exit 1
    end

    private

    def optparser(name, options)
      OptionParser.new do |opts|
        opts.program_name = name
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

        # allow user to specify custom options
        yield opts, options if block_given?

        opts.on('-p', '--port PORT', String, 'Listen on TCP port PORT') do |port|
          options[:port] = port
          options[:socket] = nil
        end

        opts.on('-H', '--host HOST', String, 'Listen on HOST') do |host|
          options[:host] = host
          options[:socket] = nil
        end

        opts.on('-s', '--socket PATH', String,
                'Listen on Unix domain socket PATH (disables TCP support)') do |path|
          options[:socket] = File.expand_path(path)
        end

        opts.on('-m', '--mode MODE', OptionParser::OctalInteger,
                'Set file permissions when using Unix socket') do |mode|
          options[:mode] = mode
        end

        opts.on('-P', '--pid PATH', String, 'Where to write the PID file') do |path|
          options[:pid_path] = File.expand_path(path)
        end

        opts.on('-l', '--log PATH', String, 'Where to write the log file') do |path|
          options[:log_path] = File.expand_path(path)
        end

        opts.on('-u', '--user USER', String,
                'Assume the identity of USER when running as a daemon') do |user|
          options[:user] = user
        end

        opts.on('-g', '--group GROUP', String,
                'Assume group GROUP when running as a daemon') do |group|
          options[:group] = group
        end

        opts.on('-f', '--force',
                'Force kill if SIGTERM fails when running "stop" command') do
          options[:force] = true
        end

        opts.separator ''
        opts.separator 'Additional Options:'

        opts.on_tail('--config PATH', String,
                'Load default parameters from YAML file at PATH') do |path|
          options[:config_path] = File.expand_path(path)
        end

        opts.on_tail('--save', 'Save current parameters into a config file') do
          options[:config_save] = true
        end

        opts.on_tail('-h', '--help', 'Display this usage information') do
          puts opts
          puts ''
          exit
        end
      end
    end

    def read_yaml(options, path)
      config = YAML.load_file(path).merge!(options)
      options.replace(config)
    rescue Errno::EACCES, Errno::EISDIR => e
      raise ConfigFileError, "unable to read config (#{e.message})"
    end

    def save_yaml(options, path)
      options[:mode] = sprintf('0%o', options[:mode]) if options[:mode]
      options.delete(:config_path)
      options.delete(:config_save)

      FileUtils.mkdir_p(File.dirname(path), mode: 0755)
      File.open(path, 'w') do |file|
        file.write options.to_yaml
      end
      File.chmod(0644, path)
    rescue Errno::EACCES, Errno::EISDIR => e
      raise ConfigFileError, "unable to save config (#{e.message})"
    end
  end
end
