module EmacsDebug
  # Builds the Elisp snippets we send to Emacs. Centralising snippet
  # construction here means every value embedded in a Lisp string literal
  # goes through `string` (and thus `escape`) -- a file path, buffer name,
  # or debug text containing a `"` or `\` can't break out of its literal
  # and corrupt the program.
  module Lisp
    HIGHLIGHT_COLOR = "#ffff00".freeze

    class << self
      # Escapes the contents of a Lisp string literal: \ -> \\, " -> \",
      # newline -> \n. The order matters -- backslashes are doubled first
      # so the escapes we add afterwards aren't themselves re-escaped.
      def escape(text)
        text.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("\n", '\\n')
      end

      # A complete Lisp string literal (surrounding quotes included) for an
      # arbitrary Ruby string.
      def string(text)
        %("#{escape(text)}")
      end

      # Opens FILE, moves point to LINE, and paints a transient highlight
      # overlay across that line.
      def open_and_highlight(file, line)
        <<~LISP.chomp
          (find-file #{string(file)})
          (goto-char (point-min))
          (forward-line (1- #{Integer(line)}))
          (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
            (overlay-put ov 'face '(:background #{string(HIGHLIGHT_COLOR)}))
            (overlay-put ov 'evaporate t))
          (recenter)
        LISP
      end

      # Fills buffer NAME with TEXT (prefixed by the trigger location) and
      # displays it.
      def display_in_buffer(name, file, line, text)
        header = "=== [Triggered at #{file}:#{Integer(line)}] ===\n\n"
        <<~LISP.chomp
          (let ((buf (get-buffer-create #{string(name)})))
            (with-current-buffer buf
              (read-only-mode -1)
              (erase-buffer)
              (insert #{string(header)})
              (insert #{string(text)})
              (special-mode))
            (display-buffer buf))
        LISP
      end
    end
  end
end
