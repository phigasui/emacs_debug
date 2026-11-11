# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class EmacsDaemonIntegrationTest < Minitest::Test
  def setup
    @orig_app_root = EmacsDebug.app_root
    @orig_container_root = EmacsDebug.container_root
    @orig_host_root = EmacsDebug.host_root
  end

  def teardown
    EmacsDebug.app_root = @orig_app_root
    EmacsDebug.container_root = @orig_container_root
    EmacsDebug.host_root = @orig_host_root
  end

  def with_env(overrides)
    saved = overrides.keys.to_h { |k| [k, ENV[k]] }
    overrides.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
    yield
  ensure
    saved&.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  def with_isolated_emacs_daemon
    skip "emacs binary not available" unless system("which emacs > /dev/null 2>&1")

    dir = Dir.mktmpdir("ed", "/tmp")
    socket_path = File.join(dir, "s")
    assert_operator socket_path.bytesize, :<, 104

    stdin, stdout, stderr, wait_thr = Open3.popen3({ "HOME" => dir }, "emacs", "-Q", "--fg-daemon=#{socket_path}")
    stdin.close
    out_buf = +""
    err_buf = +""
    out_reader = Thread.new { out_buf << stdout.read }
    err_reader = Thread.new { err_buf << stderr.read }

    deadline = Time.now + 10
    until File.socket?(socket_path)
      unless wait_thr.alive?
        out_reader.join(1)
        err_reader.join(1)
        flunk "Emacs daemon exited prematurely (#{wait_thr.value}): stdout=#{out_buf.inspect} stderr=#{err_buf.inspect}"
      end
      flunk "Timed out waiting for Emacs daemon socket at #{socket_path}: stderr=#{err_buf.inspect}" if Time.now > deadline

      sleep 0.02
    end

    with_env("EMACS_SOCKET_NAME" => socket_path, "EMACS_SERVER_FILE" => File.join(dir, "no-tcp-server")) do
      yield dir, socket_path
    end
  ensure
    if socket_path && File.socket?(socket_path)
      with_env("EMACS_SOCKET_NAME" => socket_path, "EMACS_SERVER_FILE" => nil) do
        EmacsDebug::SocketClient.eval("(kill-emacs)", timeout: 2)
      rescue StandardError
        nil
      end
    end
    if wait_thr
      unless wait_thr.join(5)
        Process.kill("TERM", wait_thr.pid)
        unless wait_thr.join(2)
          Process.kill("KILL", wait_thr.pid)
          wait_thr.join(1)
        end
      end
    end
    out_reader&.join(1)
    err_reader&.join(1)
    stdout&.close unless stdout&.closed?
    stderr&.close unless stderr&.closed?
    File.unlink(socket_path) if socket_path && File.exist?(socket_path)
    FileUtils.rm_rf(dir) if dir
  end

  def escape_elisp(str)
    str.gsub("\\") { "\\\\" }.gsub('"', '\\"').gsub("\n") { "\\n" }
  end

  def verify_in_daemon!(target_file, buffer_name:, expected_line:, expected_text:)
    escaped_file = escape_elisp(target_file)
    escaped_buffer = escape_elisp(buffer_name)
    escaped_text = escape_elisp(expected_text)

    reply = EmacsDebug::SocketClient.eval(<<~ELISP)
      (progn
        (let ((buf (get-buffer "#{escaped_buffer}")))
          (unless buf
            (error "Missing buffer %s" "#{escaped_buffer}"))
          (with-current-buffer buf
            (unless (eq major-mode 'special-mode)
              (error "Expected special-mode in %s, got %S" "#{escaped_buffer}" major-mode))
            (unless (string-match-p (regexp-quote "=== [Triggered at #{escaped_file}:#{expected_line}] ===") (buffer-string))
              (error "Missing trigger header in %s: %S" "#{escaped_buffer}" (buffer-string)))
            (unless (string-match-p (regexp-quote "#{escaped_text}") (buffer-string))
              (error "Missing payload in %s: %S" "#{escaped_buffer}" (buffer-string)))))
        (let ((fbuf (or (get-file-buffer "#{escaped_file}")
                        (find-buffer-visiting "#{escaped_file}"))))
          (unless fbuf
            (error "Target file is not open in Emacs: %s" "#{escaped_file}"))
          (with-current-buffer fbuf
            (let ((ovs nil))
              (dolist (ov (overlays-in (point-min) (point-max)))
                (when (eq (overlay-get ov 'emacs-debug) t)
                  (push ov ovs)))
              (unless (= (length ovs) 1)
                (error "Expected 1 emacs-debug overlay, got %d" (length ovs)))
              (let ((ov (car ovs)))
                (unless (equal (overlay-get ov 'face) '(:background "#ffff00"))
                  (error "Unexpected overlay face: %S" (overlay-get ov 'face)))
                (unless (= (line-number-at-pos (overlay-start ov)) #{expected_line})
                  (error "Expected highlight on line #{expected_line}, got %d" (line-number-at-pos (overlay-start ov))))))))
        "VERIFIED")
    ELISP

    assert_includes EmacsDebug::EmacsServerProtocol.unquote(reply), "VERIFIED"
  end

  def test_isolated_daemon_debug_open_error_and_server_error_propagation
    with_isolated_emacs_daemon do |dir, socket_path|
      assert_equal socket_path, EmacsDebug::SocketClient.socket_path
      assert EmacsDebug.available?

      real_dir = File.realpath(dir)
      target_file = File.join(real_dir, "sample_app.rb")
      File.write(target_file, <<~RUBY)
        module SampleApp
          def self.trigger_debug(payload)
            EmacsDebug.debug(payload)
          end

          def self.trigger_error
            raise StandardError, "isolated daemon boom"
          end
        end
      RUBY

      mod = Module.new
      load(target_file, mod)

      EmacsDebug.app_root = "#{real_dir}/"
      EmacsDebug.container_root = nil
      EmacsDebug.host_root = nil

      thread = mod::SampleApp.trigger_debug("isolated payload line 1\nline 2")
      thread.join

      verify_in_daemon!(
        target_file,
        buffer_name: "*Debug*",
        expected_line: 3,
        expected_text: "isolated payload line 1\nline 2"
      )

      begin
        mod::SampleApp.trigger_error
      rescue StandardError => e
        EmacsDebug.open_error(e)
      end

      verify_in_daemon!(
        target_file,
        buffer_name: "*Error*",
        expected_line: 7,
        expected_text: "isolated daemon boom"
      )

      err = assert_raises(EmacsDebug::EmacsServerProtocol::Error) do
        EmacsDebug::SocketClient.eval("(nonexistent-emacs-debug-symbol-for-test)")
      end
      assert_includes err.message, "nonexistent-emacs-debug-symbol-for-test"
      refute_includes err.message, "&_"
      refute_includes err.message, "&-"
    end
  end
end
