require "emacs_debug"

EmacsDebug.app_root = __dir__ + "/"
EmacsDebug.container_root = "/app/"

puts "emacsclient available?: #{EmacsDebug.available?}"

EmacsDebug.debug("hello from inside docker")
sleep 1 # EmacsDebug.debug runs asynchronously; give it time before the process exits

begin
  raise "boom"
rescue => e
  EmacsDebug.open_error(e)
end

puts "OK: debug and open_error returned without raising"
