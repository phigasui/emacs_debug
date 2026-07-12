require "socket"
require_relative "emacs_server_protocol"

module EmacsDebug
  # Talks to a TCP-mode Emacs server (`server-use-tcp` set to non-nil, e.g.
  # to reach a host Emacs from inside Docker), implementing the auth-key
  # handshake plus the same `-eval` request used by SocketClient. This
  # removes the need for the `emacsclient` binary in that setup too.
  #
  # See bin/emacs-server-file-for-docker for how the host's server file
  # gets rewritten so the container can reach it.
  module TcpClient
    Error = EmacsServerProtocol::Error

    class << self
      # The path emacsclient itself would resolve to: EMACS_SERVER_FILE (a
      # bare name under the default auth directory, or a path containing
      # "/"), else the default server file name "server".
      def server_file_path
        EmacsServerProtocol.resolve_name(ENV["EMACS_SERVER_FILE"], auth_dir)
      end

      def available?
        File.file?(server_file_path)
      end

      # Evaluates LISP on the server. Raises Error if there's no server
      # file to read, it doesn't parse, the connection is refused, or it
      # doesn't reply within TIMEOUT seconds.
      def eval(lisp, timeout: EmacsServerProtocol::DEFAULT_TIMEOUT)
        host, port, auth_key = read_server_file

        socket = TCPSocket.new(host, port)
        socket.write("-auth #{auth_key} -eval #{EmacsServerProtocol.quote(lisp)}\n")
        EmacsServerProtocol.read_reply(socket, timeout)
      rescue SystemCallError => e
        raise Error, "couldn't reach Emacs TCP server at #{host}:#{port}: #{e.message}"
      ensure
        socket&.close
      end

      private

      # Mirrors `locate-user-emacs-file`'s search order closely enough for
      # our purposes: prefer an existing "~/.emacs.d/", else the XDG-style
      # "~/.config/emacs/" (or $XDG_CONFIG_HOME/emacs/), else default to
      # "~/.emacs.d/" as Emacs itself would for a fresh install.
      def auth_dir
        xdg_config_home = ENV["XDG_CONFIG_HOME"]
        xdg_dir = File.expand_path(File.join(xdg_config_home.to_s.empty? ? "~/.config" : xdg_config_home,
                                             "emacs/server"))
        dot_emacs_dir = File.expand_path("~/.emacs.d/server")

        [dot_emacs_dir, xdg_dir].find { |dir| Dir.exist?(dir) } || dot_emacs_dir
      end

      # The file has the format written by server.el's `server-start`:
      #   <ip>:<port> <pid>\n<64-char auth key>
      # (the pid is kept only for backward compatibility and unused here).
      def read_server_file
        path = server_file_path
        raise Error, "no Emacs server file at #{path}" unless File.file?(path)

        address_line, auth_key = File.read(path).split("\n", 2)
        raise Error, "malformed Emacs server file at #{path}" unless address_line && auth_key

        host, rest = address_line.split(":", 2)
        port = rest&.split(" ", 2)&.first
        raise Error, "malformed Emacs server file at #{path}" unless host && port

        [host, Integer(port), auth_key.chomp]
      rescue ArgumentError
        raise Error, "malformed Emacs server file at #{path}"
      end
    end
  end
end
