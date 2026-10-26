# frozen_string_literal: true

require "test_helper"
require "open3"
require "tempfile"

class EmacsDebugTest < Minitest::Test
  def setup
    @orig_app_root = EmacsDebug.app_root
    @orig_container_root = EmacsDebug.container_root
    @orig_host_root = EmacsDebug.host_root
    @captured_lisp = []
  end

  def teardown
    EmacsDebug.app_root = @orig_app_root
    EmacsDebug.container_root = @orig_container_root
    EmacsDebug.host_root = @orig_host_root
  end

  def with_mocked_emacs
    orig_available = EmacsDebug.method(:available?)
    orig_eval_lisp = EmacsDebug.send(:method, :eval_lisp)
    captured = @captured_lisp

    EmacsDebug.singleton_class.define_method(:available?) { true }
    EmacsDebug.singleton_class.send(:define_method, :eval_lisp) { |lisp| captured << lisp }

    yield
  ensure
    EmacsDebug.singleton_class.define_method(:available?, orig_available)
    EmacsDebug.singleton_class.send(:define_method, :eval_lisp, orig_eval_lisp)
  end

  def test_debug_generates_elisp_with_emacs_hooks_and_fallbacks
    with_mocked_emacs do
      thread = EmacsDebug.debug("hello \"world\"\nline 2")
      thread.join
    end

    assert_equal 1, @captured_lisp.size
    lisp = @captured_lisp.first

    assert_includes lisp, "(if (and (boundp 'emacs-debug-open-file-function) emacs-debug-open-file-function)"
    assert_includes lisp, "(remove-overlays (point-min) (point-max) 'emacs-debug t)"
    assert_includes lisp, "emacs-debug-highlight-face"
    assert_includes lisp, "'(:background \"#ffff00\")"
    assert_includes lisp, "(overlay-put ov 'emacs-debug t)"
    assert_includes lisp, "(if (and (boundp 'emacs-debug-display-buffer-function) emacs-debug-display-buffer-function)"
    assert_includes lisp, "emacs-debug-buffer-mode"
    assert_includes lisp, "hello \\\"world\\\"\\nline 2"
  end

  def test_debug_formats_non_string_objects_with_pretty_inspect
    obj = { key: "value", numbers: [1, 2, 3] }
    with_mocked_emacs do
      thread = EmacsDebug.debug(obj)
      thread.join
    end

    assert_equal 1, @captured_lisp.size
    lisp = @captured_lisp.first

    assert_includes lisp, "value"
    assert_includes lisp, "[1, 2, 3]"
    assert_includes lisp, EmacsDebug.send(:elisp_escape, obj.pretty_inspect)
  end

  def test_debug_in_isolated_process_without_prior_require_pp
    code = <<~RUBY
      require "emacs_debug"
      EmacsDebug.singleton_class.define_method(:available?) { true }
      captured = nil
      EmacsDebug.singleton_class.send(:define_method, :eval_lisp) { |lisp| captured = lisp }
      t = EmacsDebug.debug({ key: "val" })
      t.join
      puts "OK" if captured && captured.include?("val")
    RUBY

    lib_path = File.expand_path("../lib", __dir__)
    out, err, status = Open3.capture3("ruby", "-I#{lib_path}", "-e", code)
    assert status.success?, "Subprocess failed: #{err}"
    assert_equal "OK\n", out
  end

  def test_open_error_translates_container_path_and_escapes_file
    EmacsDebug.app_root = "/app/"
    EmacsDebug.container_root = "/app/"
    EmacsDebug.host_root = "/Users/me/my \"project\"/"

    fake_loc = Struct.new(:absolute_path, :lineno).new("/app/models/user.rb", 42)
    fake_err = StandardError.new("invalid \"input\"")
    fake_err.define_singleton_method(:backtrace_locations) { [fake_loc] }

    with_mocked_emacs do
      EmacsDebug.open_error(fake_err)
    end

    assert_equal 1, @captured_lisp.size
    lisp = @captured_lisp.first

    assert_includes lisp, '/Users/me/my \"project\"/models/user.rb'
    assert_includes lisp, "(forward-line (1- 42))"
    assert_includes lisp, '"*Error*"'
    assert_includes lisp, 'invalid \"input\"'
  end

  def test_elisp_evaluates_in_emacs_batch_default_and_customized
    skip "emacs binary not available" unless system("which emacs > /dev/null 2>&1")

    Tempfile.create(["emacs_debug_sample", ".rb"]) do |tmp|
      tmp.write("line 1\nline 2\nline 3\nline 4\n")
      tmp.flush

      open_expr = EmacsDebug.send(:open_and_highlight, tmp.path, 3)
      disp_expr = EmacsDebug.send(:display_in_buffer, "*Debug*", tmp.path, 3, "debug payload")
      combined = "(progn #{open_expr} #{disp_expr})"

      # 1. Default behavior (zero-config fallback) + overlay cleanup on repeat
      open_expr_line2 = EmacsDebug.send(:open_and_highlight, tmp.path, 2)
      script_default = <<~ELISP
        (progn
          (defun recenter (&optional arg) nil)
          #{combined}
          #{open_expr_line2}
          (with-current-buffer (get-file-buffer "#{tmp.path}")
            (let ((ovs (overlays-in (point-min) (point-max))))
              (unless (= (length ovs) 1)
                (error "Expected exactly 1 overlay after second call, got %d" (length ovs)))
              (let ((ov (car ovs)))
                (unless (equal (overlay-get ov 'face) '(:background "#ffff00"))
                  (error "Unexpected default face: %S" (overlay-get ov 'face)))
                (unless (eq (overlay-get ov 'emacs-debug) t)
                  (error "Missing emacs-debug overlay property"))
                (unless (= (line-number-at-pos (overlay-start ov)) 2)
                  (error "Expected overlay on line 2, got %d" (line-number-at-pos (overlay-start ov)))))))
          (with-current-buffer "*Debug*"
            (unless (eq major-mode 'special-mode)
              (error "Expected special-mode, got %S" major-mode))
            (unless (string-match-p "debug payload" (buffer-string))
              (error "Missing payload in *Debug* buffer")))
          (princ "DEFAULT_OK"))
      ELISP

      out, err, status = Open3.capture3("emacs", "--batch", "--eval", script_default)
      assert status.success?, "Emacs default eval failed: #{err}"
      assert_includes out, "DEFAULT_OK"

      # 2. Custom face & custom buffer mode
      script_custom_vars = <<~ELISP
        (progn
          (defun recenter (&optional arg) nil)
          (setq emacs-debug-highlight-face 'highlight)
          (setq emacs-debug-buffer-mode #'text-mode)
          #{combined}
          (with-current-buffer (get-file-buffer "#{tmp.path}")
            (let ((ov (car (overlays-in (point-min) (point-max)))))
              (unless (eq (overlay-get ov 'face) 'highlight)
                (error "Expected highlight face, got %S" (overlay-get ov 'face)))))
          (with-current-buffer "*Debug*"
            (unless (eq major-mode 'text-mode)
              (error "Expected text-mode, got %S" major-mode)))
          (princ "CUSTOM_VARS_OK"))
      ELISP

      out, err, status = Open3.capture3("emacs", "--batch", "--eval", script_custom_vars)
      assert status.success?, "Emacs custom vars eval failed: #{err}"
      assert_includes out, "CUSTOM_VARS_OK"

      # 3. Custom open-file and display-buffer functions
      script_custom_funcs = <<~ELISP
        (progn
          (setq my-opened nil)
          (setq my-displayed nil)
          (setq emacs-debug-open-file-function
                (lambda (file line) (setq my-opened (list file line))))
          (setq emacs-debug-display-buffer-function
                (lambda (name file line text) (setq my-displayed (list name file line text))))
          #{combined}
          (unless (equal my-opened (list "#{tmp.path}" 3))
            (error "Unexpected my-opened: %S" my-opened))
          (unless (equal my-displayed (list "*Debug*" "#{tmp.path}" 3 "debug payload"))
            (error "Unexpected my-displayed: %S" my-displayed))
          (princ "CUSTOM_FUNCS_OK"))
      ELISP

      out, err, status = Open3.capture3("emacs", "--batch", "--eval", script_custom_funcs)
      assert status.success?, "Emacs custom funcs eval failed: #{err}"
      assert_includes out, "CUSTOM_FUNCS_OK"
    end
  end
end
