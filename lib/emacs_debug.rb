require_relative "emacs_debug/version"
require_relative "emacs_debug/socket_client"
require_relative "emacs_debug/tcp_client"

module EmacsDebug
  HIGHLIGHT_COLOR = "#ffff00"

  class << self
    attr_writer :app_root, :container_root, :host_root

    def app_root
      @app_root || (defined?(Rails) ? "#{Rails.root}/app/" : nil)
    end

    # Root of the checkout as seen from this process, e.g. "/app/" inside a
    # container. Paired with host_root to translate file paths so Emacs,
    # running outside the container, opens the matching file on its own
    # filesystem instead of a path that only exists in the container.
    def container_root
      @container_root || (defined?(Rails) ? "#{Rails.root}/" : nil)
    end

    # Root of the same checkout as seen by the Emacs process, e.g.
    # "/Users/me/myapp/". Typically set via EMACS_DEBUG_HOST_ROOT.
    def host_root
      @host_root || ENV["EMACS_DEBUG_HOST_ROOT"]
    end

    # Checked fresh every time (not memoized): a local Emacs server can
    # start after this process has already booted, and the file/socket
    # checks are cheap. Only the emacsclient-on-PATH fallback is memoized,
    # since PATH doesn't change at runtime.
    def available?
      SocketClient.available? || TcpClient.available? || emacsclient_on_path?
    end

    def debug(obj)
      return unless available?

      location = caller_locations(1, 1).first
      file = resolve_path(location.absolute_path || location.path)
      line = location.lineno
      text = obj.is_a?(String) ? obj : obj.pretty_inspect

      Thread.new do
        eval_lisp(<<~LISP)
          (progn
            #{open_and_highlight(file, line)}
            #{display_in_buffer("*Debug*", file, line, text)})
        LISP
      end
    end

    def open_error(exception)
      return unless available?

      app_location = exception.backtrace_locations&.find do |loc|
        app_root && loc.absolute_path&.start_with?(app_root)
      end
      return unless app_location

      file = resolve_path(app_location.absolute_path)
      line = app_location.lineno

      eval_lisp(<<~LISP)
        (progn
          #{open_and_highlight(file, line)}
          #{display_in_buffer("*Error*", file, line, exception.message)})
      LISP
    end

    private

    def resolve_path(file)
      return file unless host_root && container_root && file.start_with?(container_root)

      File.join(host_root, file.delete_prefix(container_root))
    end

    def display_in_buffer(name, file, line, text)
      escaped = elisp_escape(text)
      <<~LISP.chomp
        (let ((buf (get-buffer-create "#{name}")))
          (with-current-buffer buf
            (read-only-mode -1)
            (erase-buffer)
            (insert "=== [Triggered at #{file}:#{line}] ===\\n\\n")
            (insert "#{escaped}")
            (special-mode))
          (display-buffer buf))
      LISP
    end

    def elisp_escape(text)
      text.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }.gsub("\n") { '\\n' }
    end

    def open_and_highlight(file, line)
      <<~LISP.chomp
        (find-file "#{file}")
        (goto-char (point-min))
        (forward-line (1- #{line}))
        (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
          (overlay-put ov 'face '(:background "#{HIGHLIGHT_COLOR}"))
          (overlay-put ov 'evaporate t))
        (recenter)
      LISP
    end

    def emacsclient_on_path?
      return @emacsclient_on_path if defined?(@emacsclient_on_path)

      @emacsclient_on_path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, "emacsclient"))
      end
    end

    # Prefers talking to a local Emacs server directly, over its Unix
    # socket (SocketClient) or, e.g. for a host Emacs reached from Docker,
    # its TCP server (TcpClient). Falls back to the emacsclient binary,
    # kept around for setups those two don't cover.
    def eval_lisp(lisp)
      [SocketClient, TcpClient].each do |client|
        next unless client.available?

        begin
          client.eval(lisp)
          return
        rescue EmacsServerProtocol::Error
          # Try the next client, e.g. a stale socket/server file.
        end
      end

      system("emacsclient", "--eval", lisp, out: File::NULL, err: File::NULL) if emacsclient_on_path?
    end
  end
end
