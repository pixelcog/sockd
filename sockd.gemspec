# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'sockd/version'

Gem::Specification.new do |s|
  s.name    = "sockd"
  s.version = Sockd::VERSION
  s.license = "MIT"

  s.summary     = "A framework for single-threaded ruby socket daemons"
  s.description = "Sockd makes it easy to create a single-threaded daemon which can listen on a TCP or Unix socket and respond to commands"

  s.authors  = ["Mike Greiling"]
  s.email    = "mike@pixelcog.com"
  s.homepage = "http://pixelcog.com/"

  s.files         = `git ls-files -z`.split("\x0")
  s.test_files    = s.files.grep(%r{^(test|spec|features)/})
  s.require_paths = ["lib"]

  s.add_development_dependency "bundler", "~> 1.7"
  s.add_development_dependency "rake", "~> 10.0"
end
