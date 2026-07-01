require_relative "emacs_debug/version"

module EmacsDebug
  HIGHLIGHT_COLOR = "#ffff00"

  class << self
    attr_writer :app_root

    def app_root
      @app_root || (defined?(Rails) ? "#{Rails.root}/app/" : nil)
    end

    def debug(obj)
      location = caller_locations(1, 1).first
      file = location.absolute_path || location.path
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
      app_location = exception.backtrace_locations&.find do |loc|
        app_root && loc.absolute_path&.start_with?(app_root)
      end
      return unless app_location

      file = app_location.absolute_path
      line = app_location.lineno

      eval_lisp(<<~LISP)
        (progn
          #{open_and_highlight(file, line)}
          #{display_in_buffer("*Error*", file, line, exception.message)})
      LISP
    end

    private

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

    def eval_lisp(lisp)
      system("emacsclient", "--eval", lisp, out: File::NULL, err: File::NULL)
    end
  end
end
