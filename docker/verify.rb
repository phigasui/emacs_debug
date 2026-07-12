require "emacs_debug"

EmacsDebug.app_root = "#{__dir__}/"
EmacsDebug.container_root = "/app/"

puts "EmacsDebug.available?: #{EmacsDebug.available?}"

EmacsDebug.debug("hello from inside docker")

begin
  raise "boom"
rescue StandardError => e
  EmacsDebug.open_error(e)
end

# debug and open_error both run asynchronously; give the background threads
# time to reach Emacs before the process exits.
sleep 1

puts "OK: debug and open_error returned without raising"
