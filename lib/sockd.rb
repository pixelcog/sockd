require "sockd/errors"
require "sockd/optparse"
require "sockd/runner"
require "sockd/version"

module Sockd

  # instantiate a new sockd service
  def self.define(name, options = {}, &block)
    Runner.define(name, options, &block)
  end

  # instantiate command line option parser
  def self.optparse(name, defaults = {}, &block)
    OptionParser.new(name, defaults, &block)
  end

  # instantiate and run a sockd service using command line arguments
  def self.run(name, options = {}, &block)
    runner = define(name, options, &block)
    parser = optparse(runner.name, runner.options)
    argv = parser.parse!
    runner.run(*argv)
  rescue OptionParserError, BadCommandError => e
    warn "Error: #{e.message}"
    warn "#{parser}\n"
    exit
  rescue SockdError => e
    warn "Error: #{e.message}"
    exit
  end
end
