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
      # overlay across that line. Users can override the behaviour from
      # Emacs: `emacs-debug-open-file-function` replaces the whole step and
      # `emacs-debug-highlight-face` replaces the default face.
      def open_and_highlight(file, line)
        file_literal = string(file)
        line = Integer(line)
        <<~LISP.chomp
          (if (and (boundp 'emacs-debug-open-file-function) emacs-debug-open-file-function)
              (funcall emacs-debug-open-file-function #{file_literal} #{line})
            (find-file #{file_literal})
            (goto-char (point-min))
            (forward-line (1- #{line}))
            (remove-overlays (point-min) (point-max) 'emacs-debug t)
            (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
              (overlay-put ov 'face (if (and (boundp 'emacs-debug-highlight-face) emacs-debug-highlight-face)
                                        emacs-debug-highlight-face
                                      '(:background #{string(HIGHLIGHT_COLOR)})))
              (overlay-put ov 'emacs-debug t)
              (overlay-put ov 'evaporate t))
            (recenter))
        LISP
      end

      # Fills buffer NAME with TEXT (prefixed by the trigger location) and
      # displays it. `emacs-debug-display-buffer-function` replaces the
      # whole step; `emacs-debug-buffer-mode` replaces `special-mode`.
      def display_in_buffer(name, file, line, text)
        line = Integer(line)
        header = "=== [Triggered at #{file}:#{line}] ===\n\n"
        <<~LISP.chomp
          (if (and (boundp 'emacs-debug-display-buffer-function) emacs-debug-display-buffer-function)
              (funcall emacs-debug-display-buffer-function #{string(name)} #{string(file)} #{line} #{string(text)})
            (let ((buf (get-buffer-create #{string(name)})))
              (with-current-buffer buf
                (read-only-mode -1)
                (erase-buffer)
                (insert #{string(header)})
                (insert #{string(text)})
                (funcall (if (and (boundp 'emacs-debug-buffer-mode) emacs-debug-buffer-mode)
                             emacs-debug-buffer-mode
                           #'special-mode)))
              (display-buffer buf)))
        LISP
      end
    end
  end
end
