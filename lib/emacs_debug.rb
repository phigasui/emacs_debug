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
    # checks are cheap.
    def available?
      SocketClient.available? || TcpClient.available?
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
      escaped_name = elisp_escape(name)
      escaped_file = elisp_escape(file)
      escaped_text = elisp_escape(text)
      <<~LISP.chomp
        (if (and (boundp 'emacs-debug-display-buffer-function) emacs-debug-display-buffer-function)
            (funcall emacs-debug-display-buffer-function "#{escaped_name}" "#{escaped_file}" #{line} "#{escaped_text}")
          (let ((buf (get-buffer-create "#{escaped_name}")))
            (with-current-buffer buf
              (read-only-mode -1)
              (erase-buffer)
              (insert "=== [Triggered at #{escaped_file}:#{line}] ===\\n\\n")
              (insert "#{escaped_text}")
              (funcall (if (and (boundp 'emacs-debug-buffer-mode) emacs-debug-buffer-mode)
                           emacs-debug-buffer-mode
                         #'special-mode)))
            (display-buffer buf)))
      LISP
    end

    def elisp_escape(text)
      text.to_s.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }.gsub("\n") { '\\n' }
    end

    def open_and_highlight(file, line)
      escaped_file = elisp_escape(file)
      <<~LISP.chomp
        (if (and (boundp 'emacs-debug-open-file-function) emacs-debug-open-file-function)
            (funcall emacs-debug-open-file-function "#{escaped_file}" #{line})
          (find-file "#{escaped_file}")
          (goto-char (point-min))
          (forward-line (1- #{line}))
          (remove-overlays (point-min) (point-max) 'emacs-debug t)
          (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
            (overlay-put ov 'face (if (and (boundp 'emacs-debug-highlight-face) emacs-debug-highlight-face)
                                      emacs-debug-highlight-face
                                    '(:background "#{HIGHLIGHT_COLOR}")))
            (overlay-put ov 'emacs-debug t)
            (overlay-put ov 'evaporate t))
          (recenter))
      LISP
    end

    # Talks to a local Emacs server directly, over its Unix socket
    # (SocketClient) or, e.g. for a host Emacs reached from Docker, its TCP
    # server (TcpClient). No emacsclient binary is used or required.
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
    end
  end
end
