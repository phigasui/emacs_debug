module EmacsDebug
  # Shared wire-protocol bits used by both SocketClient (Unix-domain) and
  # TcpClient (TCP + auth key), per Emacs's lisp/server.el.
  module EmacsServerProtocol
    class Error < StandardError; end

    UNQUOTE_MAP = {
      "&" => "&",
      "-" => "-",
      "n" => "\n",
      "_" => " "
    }.freeze
    private_constant :UNQUOTE_MAP

    class << self
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

      # Inverse of `quote` (mirrors Emacs's `server-unquote-arg`).
      def unquote(str)
        str.gsub(/&([&\-n_])/) { UNQUOTE_MAP.fetch(Regexp.last_match(1)) }
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
      #
      # Raises Error if the server does not respond within TIMEOUT seconds
      # or if it replies with `-error`.
      def read_reply(socket, timeout)
        deadline = Time.now + timeout
        buffer = +""
        loop do
          remaining = deadline - Time.now
          if remaining <= 0 || !IO.select([socket], nil, nil, remaining)
            raise Error, "Emacs server did not respond within #{timeout}s"
          end

          begin
            buffer << socket.readpartial(4096)
          rescue EOFError
            break
          end
          break if buffer.match?(/^(?:-print |-error )[^\n]*\n/)
        end
        buffer = decode_utf8(buffer)
        raise_if_error!(buffer)
        buffer
      end

      private

      def decode_utf8(buffer)
        return buffer if buffer.encoding == Encoding::UTF_8 && buffer.valid_encoding?

        utf8 = buffer.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : utf8.scrub
      end

      def raise_if_error!(buffer)
        buffer.each_line(chomp: true) do |line|
          if line.start_with?("-error ")
            message = unquote(line.delete_prefix("-error "))
            raise Error, message.empty? ? "Emacs server returned an error" : message
          elsif line == "-error"
            raise Error, "Emacs server returned an error"
          end
        end
      end
    end
  end
end
