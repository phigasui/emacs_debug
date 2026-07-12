module EmacsDebug
  # Shared wire-protocol bits used by both SocketClient (Unix-domain) and
  # TcpClient (TCP + auth key), per Emacs's lisp/server.el.
  module EmacsServerProtocol
    class Error < StandardError; end

    # How long a client waits for a reply before giving up. Shared so both
    # transports time out identically.
    DEFAULT_TIMEOUT = 10

    class << self
      # Resolves an emacsclient-style name the way both clients need it:
      # a value containing "/" is treated as a path (expanded); a bare name
      # is looked up under default_dir; a nil name falls back to "server".
      # This is the shared rule behind EMACS_SOCKET_NAME / EMACS_SERVER_FILE.
      def resolve_name(name, default_dir)
        return File.expand_path(name) if name&.include?("/")

        File.join(default_dir, name || "server")
      end

      # Mirrors Emacs's `server-quote-arg`: & -> &&, - -> &-, "\n" -> &n,
      # " " -> &_, so the request is a single line with no unescaped spaces.
      def quote(str)
        str.each_char.map do |c|
          case c
          when "&" then "&&"
          when "-" then "&-"
          when "\n" then "&n"
          when " " then "&_"
          else c
          end
        end.join
      end

      # Reads until the server's reply (`-print`/`-error`) has fully
      # arrived, or EOF/timeout. Emacs may keep the connection open for
      # several more seconds afterward (`server-return-error` does a 2s
      # `sit-for` before replying, then closes 5s later), so we can't just
      # wait for the socket to close.
      #
      # A literal "-print " or "-error " can only appear here as an actual
      # protocol line: within the reply, every "-" in the evaluated value
      # is itself &-escaped (see `quote`), so it can't be confused with
      # this early-exit check.
      def read_reply(socket, timeout)
        deadline = Time.now + timeout
        buffer = +""
        loop do
          remaining = deadline - Time.now
          raise Error, "Emacs server did not respond within #{timeout}s" if remaining <= 0
          break unless socket.wait_readable(remaining)

          begin
            buffer << socket.readpartial(4096)
          rescue EOFError
            break
          end
          break if buffer.include?("-print ") || buffer.include?("-error ")
        end
        buffer
      end
    end
  end
end
