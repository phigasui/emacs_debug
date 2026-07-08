require 'socket'
require_relative 'emacs_server_protocol'

module EmacsDebug
  # Talks directly to a running Emacs server over its Unix-domain socket,
  # implementing the subset of the wire protocol described in Emacs's
  # lisp/server.el (see `server-quote-arg` and `server--process-filter-1`)
  # needed to send a `-eval` request. This removes the need for the
  # `emacsclient` binary when Emacs is running on the same machine.
  #
  # TCP servers (`server-use-tcp`, e.g. the Docker host-Emacs setup) are
  # handled by TcpClient instead.
  module SocketClient
    Error = EmacsServerProtocol::Error

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
        socket.write("-eval #{EmacsServerProtocol.quote(lisp)}\n")
        EmacsServerProtocol.read_reply(socket, timeout)
      ensure
        socket&.close
      end

      private

      def socket_dir
        runtime_dir = ENV['XDG_RUNTIME_DIR']
        return File.join(runtime_dir, 'emacs') unless runtime_dir.to_s.empty?

        File.join(ENV['TMPDIR'] || '/tmp', "emacs#{Process.uid}")
      end
    end
  end
end
