require "socket"
require "timeout"
require "fileutils"

module Sockd
  class Runner

    class ServiceError < RuntimeError; end

    attr_reader :options, :name

    class << self
      alias define new
    end

    def initialize(name = nil, options = {}, &block)
      @name = name || File.basename($0)
      @options = {
        :host      => "127.0.0.1",
        :port      => 0,
        :socket    => false,
        :mode      => 0660,
        :daemonize => true,
        :pid_path  => "/var/run/#{safe_name}.pid",
        :log_path  => false,
        :force     => false,
        :user      => false,
        :group     => false
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
      raise ArgumentError, "no message handler provided" unless @handle
      @handle.call(message, socket)
    end

    # start our service
    def start
      server do |server|

        if options[:daemonize]
          pid = daemon_running?
          raise ServiceError, "#{name} process already running (#{pid})" if pid
          puts "starting #{name} process..."
          unless daemonize
            unless send('ping', 10).chomp == 'pong'
              raise ServiceError, "invalid ping response"
            end
            return self
          end
        end

        drop_privileges options[:user], options[:group]

        setup

        on_interrupt do |signal|
          log "#{signal} received, shutting down..."
          teardown
          # cleanup
          exit 130
        end

        log "listening on #{server.local_address.inspect_sockaddr}"

        while true
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

    # stop our service
    def stop
      if daemon_running?
        pid = stored_pid
        Process.kill('TERM', pid)
        puts "SIGTERM sent to #{name} (#{pid})"
        if !wait_until(2) { daemon_stopped? pid } && options[:force]
          Process.kill('KILL', pid)
          puts "SIGKILL sent to #{name} (#{pid})"
        end
        raise ServiceError, "unable to stop #{name} process" if daemon_running?
      else
        warn "#{name} process not running"
      end
      self
    end

    # restart our service
    def restart
      stop
      start
    end

    # send a message to a running service and return the response
    def send(message, timeout = 30)
      client do |sock|
        sock.write "#{message}\r\n"
        ready = IO.select([sock], nil, nil, timeout)
        raise ServiceError, "timed out waiting for server response" unless ready
        sock.recv(256)
      end
    rescue Errno::ECONNREFUSED, Errno::ENOENT
      raise ServiceError, "#{name} process not running" unless daemon_running?
      raise ServiceError, "unable to establish connection"
    end

    # output a timestamped log message
    def log(message)
      puts Time.now.strftime('[%d-%b-%Y %H:%M:%S] ') + message
    end

    protected

    # return a UNIXServer or TCPServer instance depending on config
    def server
      server = if options[:socket]
        begin
          UNIXServer.new(options[:socket])
        rescue Errno::EADDRINUSE
          begin
            send('ping', 20)
          rescue ServiceError
            # socket stale, reopening
            File.delete(options[:socket])
            UNIXServer.new(options[:socket])
          else
            raise ServiceError, "socket #{options[:socket]} already in use by another process"
          end
        end.tap do
          # get user and group ids
          uid, gid = user_id(options[:user]) if options[:user]
          gid = group_id(options[:group]) if options[:group]
          File.chown(uid, gid, options[:socket]) if uid || gid

          # ensure mode is octal if string provided
          options[:mode] = options[:mode].to_i(8) if options[:mode].is_a?(String)
          File.chmod(options[:mode], options[:socket]) if options[:mode] != 0
        end
      else
        TCPServer.new(options[:host], options[:port])
      end
      begin
        yield(server)
      ensure
        server.close
      end
    rescue Errno::EACCES
      sock = options[:socket] || "#{options[:host]}:#{options[:port]}"
      raise ServiceError, "unable to open socket: #{sock} (check permissions)"
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
      raise ServiceError, "unable to open socket: #{sock} (check permissions)"
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
        raise ServiceError, "failed to start #{name} service"
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
      uid, gid = user_id(user) if user
      gid = group_id(group) if group

      Process::Sys.setgid(gid) if gid
      Process::Sys.setuid(uid) if uid
    rescue Errno::EPERM => e
      raise ServiceError, "unable to drop privileges (#{e})"
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
        raise ServiceError, "unable to open file: #{path} (check permissions)"
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

    def user_id(user)
      user = Etc.getpwnam(user)
      [user.uid, user.gid]
    rescue ArgumentError
      raise ServiceError, "unable to find user: #{user}"
    end

    def group_id(group)
      Etc.getgrnam(group).gid
    rescue ArgumentError
      raise ServiceError, "unable to find group: #{user}"
    end
  end
end
