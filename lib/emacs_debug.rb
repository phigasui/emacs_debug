require "pp"
require_relative "emacs_debug/version"
require_relative "emacs_debug/configuration"
require_relative "emacs_debug/lisp"
require_relative "emacs_debug/socket_client"
require_relative "emacs_debug/tcp_client"

module EmacsDebug
  # Clients tried, in order, when reaching Emacs. A local Unix-domain
  # socket is preferred; the TCP server (e.g. a host Emacs reached from
  # Docker) is the fallback. Both `available?` and `eval_lisp` iterate this
  # single list so the priority lives in one place.
  CLIENTS = [SocketClient, TcpClient].freeze

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    # Delegate the config accessors so the public API stays
    # `EmacsDebug.app_root = ...` etc.
    %i[app_root app_root= container_root container_root= host_root host_root=].each do |m|
      define_method(m) { |*args| configuration.public_send(m, *args) }
    end

    # Checked fresh every time (not memoized): a local Emacs server can
    # start after this process has already booted, and the file/socket
    # checks are cheap.
    def available?
      CLIENTS.any?(&:available?)
    end

    def debug(obj)
      return unless available?

      location = caller_locations(1, 1).first
      file = configuration.resolve_path(location.absolute_path || location.path)
      line = location.lineno
      text = obj.is_a?(String) ? obj : obj.pretty_inspect

      run_async do
        eval_lisp(<<~LISP)
          (progn
            #{Lisp.open_and_highlight(file, line)}
            #{Lisp.display_in_buffer('*Debug*', file, line, text)})
        LISP
      end
    end

    def open_error(exception)
      return unless available?

      app_root = configuration.app_root
      app_location = exception.backtrace_locations&.find do |loc|
        app_root && loc.absolute_path&.start_with?(app_root)
      end
      return unless app_location

      file = configuration.resolve_path(app_location.absolute_path)
      line = app_location.lineno

      run_async do
        eval_lisp(<<~LISP)
          (progn
            #{Lisp.open_and_highlight(file, line)}
            #{Lisp.display_in_buffer('*Error*', file, line, exception.message)})
        LISP
      end
    end

    private

    # Runs the Emacs interaction off the caller's thread so neither `debug`
    # nor `open_error` ever blocks the app on network I/O (a client waits
    # up to its timeout for a reply). Exceptions are swallowed with a
    # warning rather than crashing the background thread silently -- this is
    # opportunistic debug output, never something that should take the app
    # down.
    def run_async
      Thread.new do
        yield
      rescue StandardError => e
        warn "emacs_debug: #{e.class}: #{e.message}"
      end
    end

    # Talks to a local Emacs server directly, over its Unix socket
    # (SocketClient) or, e.g. for a host Emacs reached from Docker, its TCP
    # server (TcpClient). No emacsclient binary is used or required.
    def eval_lisp(lisp)
      reached = CLIENTS.any? do |client|
        next false unless client.available?

        client.eval(lisp)
        true
      rescue EmacsServerProtocol::Error
        # Try the next client, e.g. a stale socket/server file.
        false
      end
      warn "emacs_debug: no reachable Emacs server accepted the request" unless reached
    end
  end
end
