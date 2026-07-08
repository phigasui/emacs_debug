require_relative "lib/emacs_debug/version"

Gem::Specification.new do |spec|
  spec.name = "emacs_debug"
  spec.version = EmacsDebug::VERSION
  spec.authors = ["phigasui"]
  spec.summary = "Debug Ruby applications with Emacs integration"
  spec.description = "Opens source files in Emacs at the call site with highlighted lines and displays debug output or error messages in dedicated buffers, talking to Emacs's server directly (no emacsclient binary required)."
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
end
