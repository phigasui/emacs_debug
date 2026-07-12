require "test_helper"

class SocketClientTest < Minitest::Test
  Client = EmacsDebug::SocketClient

  def setup
    @saved_env = ENV.to_hash.slice(
      "EMACS_SOCKET_NAME", "XDG_RUNTIME_DIR", "TMPDIR"
    )
  end

  def teardown
    %w[EMACS_SOCKET_NAME XDG_RUNTIME_DIR TMPDIR].each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
  end

  def test_socket_path_uses_absolute_name_when_it_contains_slash
    ENV["EMACS_SOCKET_NAME"] = "/custom/place/mysocket"
    assert_equal "/custom/place/mysocket", Client.socket_path
  end

  def test_socket_path_expands_bare_name_under_socket_dir
    ENV.delete("EMACS_SOCKET_NAME")
    ENV.delete("XDG_RUNTIME_DIR")
    ENV["TMPDIR"] = "/some/tmp"
    assert_equal "/some/tmp/emacs#{Process.uid}/server", Client.socket_path
  end

  def test_socket_path_prefers_xdg_runtime_dir
    ENV.delete("EMACS_SOCKET_NAME")
    ENV["XDG_RUNTIME_DIR"] = "/run/user/1000"
    assert_equal "/run/user/1000/emacs/server", Client.socket_path
  end

  def test_socket_path_honours_bare_socket_name
    ENV["EMACS_SOCKET_NAME"] = "myname"
    ENV["XDG_RUNTIME_DIR"] = "/run/user/1000"
    assert_equal "/run/user/1000/emacs/myname", Client.socket_path
  end

  def test_available_is_false_without_a_socket
    ENV["EMACS_SOCKET_NAME"] = "/nonexistent/path/socket"
    refute Client.available?
  end
end
