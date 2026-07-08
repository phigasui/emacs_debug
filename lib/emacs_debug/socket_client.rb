require 'socket'

module EmacsDebug
  # Talks directly to a running Emacs server over its Unix-domain socket,
  # implementing the subset of the wire protocol described in Emacs's
  # lisp/server.el (see `server-quote-arg` and `server--process-filter-1`)
  # needed to send a `-eval` request. This removes the need for the
  # `emacsclient` binary when Emacs is running on the same machine.
  #
  # TCP servers (`server-use-tcp`, e.g. the Docker host-Emacs setup) are
  # out of scope here and still go through `emacsclient` in emacs_debug.rb.
  module SocketClient
    class Error < StandardError; end

    class << self
      # The path emacsclient itself would resolve to: EMACS_SOCKET_NAME (a
      # bare name under the default socket directory, or a path containing
      # "/"), else the default socket name "server".
      def socket_path
        name = ENV['EMACS_SOCKET_NAME']
        return File.expand_path(name) if name && name.include?('/')

        File.join(socket_dir, name || 'server')
      end

      def available?
        File.socket?(socket_path)
      end

      # Evaluates LISP on the server. Raises Error if there's no server to
      # talk to, or if it doesn't reply within TIMEOUT seconds. The reply
      # is not parsed: callers only care that the eval was submitted.
      def eval(lisp, timeout: 10)
        path = socket_path
        raise Error, "no Emacs socket at #{path}" unless File.socket?(path)

        socket = UNIXSocket.new(path)
        socket.write("-eval #{quote(lisp)}\n")
        read_reply(socket, timeout)
      ensure
        socket&.close
      end

      private

      def socket_dir
        runtime_dir = ENV['XDG_RUNTIME_DIR']
        return File.join(runtime_dir, 'emacs') unless runtime_dir.to_s.empty?

        File.join(ENV['TMPDIR'] || '/tmp', "emacs#{Process.uid}")
      end

      # Reads until the server's reply (`-print`/`-error`) has fully
      # arrived, or EOF/timeout. Emacs may keep the connection open for
      # several more seconds afterward (`server-return-error` does a
      # 2s `sit-for` before replying, then closes 5s later), so we can't
      # just wait for the socket to close.
      #
      # A literal "-print " or "-error " can only appear here as an actual
      # protocol line: within the reply, every "-" in the evaluated value
      # is itself &-escaped (see `quote`), so it can't be confused with
      # this early-exit check.
      def read_reply(socket, timeout)
        deadline = Time.now + timeout
        buffer = +''
        loop do
          remaining = deadline - Time.now
          raise Error, "Emacs server did not respond within #{timeout}s" if remaining <= 0
          break unless IO.select([socket], nil, nil, remaining)

          begin
            buffer << socket.readpartial(4096)
          rescue EOFError
            break
          end
          break if buffer.include?('-print ') || buffer.include?('-error ')
        end
        buffer
      end

      # Mirrors Emacs's `server-quote-arg`: & -> &&, - -> &-, "\n" -> &n,
      # " " -> &_, so the request is a single line with no unescaped spaces.
      def quote(str)
        str.each_char.map do |c|
          case c
          when '&' then '&&'
          when '-' then '&-'
          when "\n" then '&n'
          when ' ' then '&_'
          else c
          end
        end.join
      end
    end
  end
end
