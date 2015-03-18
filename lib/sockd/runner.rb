require "logger"
require "socket"
require "fileutils"
require "sockd/errors"

module Sockd
  class Runner

    attr_reader :options, :name

    class << self
      def define(*args, &block)
        self.new(*args, &block)
      end
    end

    def initialize(name, options = {}, &block)
      @name = name
      @options = {
        :host      => "127.0.0.1",
        :port      => 0,
        :socket    => false,
        :daemonize => true,
        :pid_path  => "/var/run/#{safe_name}.pid",
        :log_path  => false,
        :force     => false,
        :user      => nil,
        :group     => nil
      }.merge(options)

      [:setup, :teardown, :handle].each do |opt|
        self.public_send(opt, &options[opt]) if options[opt].respond_to?(:call)
      end

      yield self if block_given?
    end

    # merge options when set with self.options = {...}
    def options=(val)
      @options.merge!(val)
    end

    # generate a path-safe and username-safe string from our daemon name
    def safe_name
      name.gsub(/(^[0-9]*|[^0-9a-z])/i, '')
    end

    # define a "setup" callback by providing a block, or trigger the callback
    # @runner.setup { |opts| Server.new(...) }
    def setup(&block)
      return self if block_given? && @setup = block
      @setup.call(self) if @setup
    end

    # define a "teardown" callback by providing a block, or trigger the callback
    # @runner.teardown { log "shutting down" }
    def teardown(&block)
      return self if block_given? && @teardown = block
      @teardown.call(self) if @teardown
    end

    # define our socket handler by providing a block, or trigger the callback
    # with the provided message
    # @runner.handle { |msg| if msg == 'foo' then return 'bar' ... }
    def handle(message = nil, socket = nil, &block)
      return self if block_given? && @handle = block
      @handle || (raise SockdError, "No message handler provided.")
      @handle.call(message, socket)
    end

    # call one of start, stop, restart, or send
    def run(method, *args)
      if %w(start stop restart send).include?(method)
        begin
          self.public_send method.to_sym, *args
        rescue ArgumentError => e
          raise unless e.backtrace[1].include? "in `public_send"
          raise BadCommandError, "wrong number of arguments for command: #{method}"
        end
      else
        raise BadCommandError, "invalid command: #{method}"
      end
    end

    # start our service
    def start
      if options[:daemonize]
        pid = daemon_running?
        raise ProcError, "#{name} process already running (#{pid})" if pid
        log "starting #{name} process..."
        return self unless daemonize
      end

      drop_privileges options[:user], options[:group]

      setup

      on_interrupt do |signal|
        log "#{signal} received, shutting down..."
        teardown
        cleanup
        exit 130
      end

      serve
    end

    # stop our service
    def stop
      if daemon_running?
        pid = stored_pid
        Process.kill('TERM', pid)
        log "SIGTERM sent to #{name} (#{pid})"
        if !wait_until(2) { daemon_stopped? pid } && options[:force]
          Process.kill('KILL', pid)
          log "SIGKILL sent to #{name} (#{pid})"
        end
        raise ProcError.new("unable to stop #{name} process") if daemon_running?
      else
        log "#{name} process not running"
      end
      self
    end

    # restart our service
    def restart
      stop
      start
    end

    # send a message to a running service and return the response
    def send(*args)
      raise ArgumentError if args.empty?
      message = args.join(' ')
      response = nil
      begin
        client do |sock|
          sock.write message + "\r\n"
          response = sock.gets
        end
      rescue Errno::ECONNREFUSED, Errno::ENOENT
        unless daemon_running?
          abort "#{name} process not running"
        end
        abort "unable to establish connection"
      end
      puts response
    end

    protected

    # run a server loop, passing data off to our handler
    def serve
      server do |server|
        log "listening on " + server.local_address.inspect_sockaddr
        while 1
          sock = server.accept
          begin
            # wait for input
            if IO.select([sock], nil, nil, 2.0)
              msg = sock.recv(256, Socket::MSG_PEEK)
              if msg.chomp == "ping"
                sock.print "pong\r\n"
              else
                handle msg, sock
              end
            else
              log "connection timed out"
            end
          rescue Errno::EPIPE, Errno::ECONNRESET
            log "connection broken"
          end
          sock.close unless sock.closed?
        end
      end
    end

    # return a UNIXServer or TCPServer instance depending on config
    def server(&block)
      if options[:socket]
        UNIXServer.open(options[:socket], &block)
      else
        TCPServer.open(options[:host], options[:port], &block)
      end
    rescue Errno::EACCES
      sock = options[:socket] || "#{options[:host]}:#{options[:port]}"
      raise ProcError, "unable to open socket: #{sock} (check permissions)"
    end

    # return a UNIXSocket or TCPSocket instance depending on config
    def client(&block)
      if options[:socket]
        UNIXSocket.open(options[:socket], &block)
      else
        TCPSocket.open(options[:host], options[:port], &block)
      end
    rescue Errno::EACCES
      sock = options[:socket] || "#{options[:host]}:#{options[:port]}"
      raise ProcError, "unable to open socket: #{sock} (check permissions)"
    end

    # clean up UNIXSocket upon termination
    def cleanup
      if options[:socket] && File.exists?(options[:socket])
        File.delete(options[:socket])
      end
    rescue StandardError
      raise ProcError, "unable to unlink socket: #{options[:socket]} (check permissions)"
    end

    # handle process termination signals
    def on_interrupt(&block)
      trap("INT")  { yield "SIGINT" }
      trap("QUIT") { yield "SIGQUIT" }
      trap("TERM") { yield "SIGTERM" }
    end

    # daemonize a process. returns true from the forked process, false otherwise
    def daemonize

      # ensure pid file and log file are writable if provided
      pid_path = options[:pid_path] ? writable_file(options[:pid_path]) : nil
      log_path = options[:log_path] ? writable_file(options[:log_path]) : nil

      unless fork
        Process.setsid
        exit if fork
        File.umask 0000
        Dir.chdir "/"

        # save pid file
        File.open(pid_path, 'w') { |f| f.write Process.pid } if pid_path

        # redirect our io
        setup_logging(log_path)

        # trap and ignore SIGHUP
        Signal.trap('HUP') {}

        # trap reopen our log files on SIGUSR1
        Signal.trap('USR1') { setup_logging(log_path) }

        return true
      end

      Process.waitpid
      unless wait_until { daemon_running? }
        raise ProcError, "failed to start #{@name} service"
      end
    end

    # returns the process id if a daemon is running with our pid file
    def daemon_running?(pid = nil)
      pid ||= stored_pid
      Process.kill(0, pid) if pid
      pid
    rescue Errno::ESRCH
      false
    end

    # reverse of daemon_running?
    def daemon_stopped?(pid = nil)
      !daemon_running? pid
    end

    # drop privileges to the specified user and group
    def drop_privileges(user, group)
      uid = Etc.getpwnam(user).uid if user
      gid = Etc.getgrnam(group).gid if group
      gid = Etc.getpwnam(user).gid if group.nil? && user

      Process::Sys.setuid(uid) if uid
      Process::Sys.setgid(gid) if gid
    rescue ArgumentError => e
      # user or group does not exist
      raise ProcError, "unable to drop privileges (#{e})"
    end

    # redirect our output as per configuration
    def setup_logging(log_path)
      log_path ||= '/dev/null'
      $stdin.reopen '/dev/null'
      $stdout.reopen(log_path, 'a')
      $stderr.reopen $stdout
      $stdout.sync = true
    end

    # returns the pid stored in our pid_path
    def stored_pid
      return false unless options[:pid_path]
      path = File.expand_path(options[:pid_path])
      return false unless File.file?(path) && !File.zero?(path)
      File.read(path).chomp.to_i
    end

    # ensure a writable file exists at the specified path
    def writable_file(path)
      path = File.expand_path(path)
      begin
        FileUtils.mkdir_p(File.dirname(path), :mode => 0755)
        FileUtils.touch path
        File.chmod(0644, path)
      rescue Errno::EACCES, Errno::EISDIR
      end
      unless File.file?(path) && File.writable?(path)
        raise ProcError, "unable to open file: #{path} (check permissions)"
      end
      path
    end

    def wait_until(timer = 5, interval = 0.1, &block)
      until timer < 0 or block.call
        timer -= interval
        sleep interval
      end
      timer > 0
    end

    def log(message)
      puts Time.now.strftime('%Y-%m-%d %H:%M:%S: ') + message
    end
  end
end
