# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "socket"
require "tmpdir"

class EmacsServerProtocolTest < Minitest::Test
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

  def serve_once(server, reply)
    ready_to_close = Queue.new
    received = nil
    thread = Thread.new do
      if IO.select([server], nil, nil, 2)
        client = server.accept
        received = client.gets("\n")
        client.write(reply)
        client.flush
        ready_to_close.pop
      end
    ensure
      client&.close
    end

    yield lambda {
      ready_to_close << true
      thread.join(2)
      received
    }
  ensure
    ready_to_close << true
    thread&.join(2)
    server&.close
  end

  def with_unix_server(reply)
    dir = Dir.mktmpdir("ed", "/tmp")
    path = File.join(dir, "s")
    assert_operator path.bytesize, :<, 104

    server = UNIXServer.new(path)
    serve_once(server, reply) do |read_received|
      yield path, read_received
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def with_tcp_server(reply, auth_key: "test-auth-key-123")
    dir = Dir.mktmpdir("ed", "/tmp")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server_file = File.join(dir, "server")
    File.write(server_file, "127.0.0.1:#{port} 12345\n#{auth_key}\n")

    serve_once(server, reply) do |read_received|
      yield server_file, read_received
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_quote_and_unquote_roundtrip
    samples = [
      "simple",
      "(progn\n  (message \"a & b - c\"))",
      "&&-&&n&_",
      "日本語 - & \n テスト"
    ]

    samples.each do |sample|
      quoted = EmacsDebug::EmacsServerProtocol.quote(sample)
      refute_includes quoted, " "
      refute_includes quoted, "\n"
      assert_equal sample, EmacsDebug::EmacsServerProtocol.unquote(quoted)
    end
  end

  def test_read_reply_returns_before_eof_on_print
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM)
    server_sock.write("-emacs-pid 1234\n-print nil&n\n")
    server_sock.flush

    reply = EmacsDebug::EmacsServerProtocol.read_reply(client_sock, 1)
    assert_equal "-emacs-pid 1234\n-print nil&n\n", reply
  ensure
    client_sock&.close
    server_sock&.close
  end

  def test_read_reply_raises_unquoted_error_while_socket_stays_open
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM)
    server_sock.write("-emacs-pid 1234\n-error Symbol's&_function&_is&_void:&_foo&-bar&n&&&_baz\n")
    server_sock.flush

    err = assert_raises(EmacsDebug::EmacsServerProtocol::Error) do
      EmacsDebug::EmacsServerProtocol.read_reply(client_sock, 1)
    end
    assert_equal "Symbol's function is void: foo-bar\n& baz", err.message
  ensure
    client_sock&.close
    server_sock&.close
  end

  def test_read_reply_waits_for_complete_chunked_error_line_and_utf8
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM)
    writer = Thread.new do
      payload = "-emacs-pid 1234\n-error 日本語&_エラー\n".b
      server_sock.write(payload[0, 23])
      server_sock.flush
      sleep 0.02
      server_sock.write(payload[23..])
      server_sock.flush
    end

    err = assert_raises(EmacsDebug::EmacsServerProtocol::Error) do
      EmacsDebug::EmacsServerProtocol.read_reply(client_sock, 2)
    end
    assert_equal "日本語 エラー", err.message
  ensure
    writer&.join(2)
    client_sock&.close
    server_sock&.close
  end

  def test_read_reply_handles_error_on_eof_without_trailing_newline
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM)
    server_sock.write("-error eof&_error")
    server_sock.close

    err = assert_raises(EmacsDebug::EmacsServerProtocol::Error) do
      EmacsDebug::EmacsServerProtocol.read_reply(client_sock, 1)
    end
    assert_equal "eof error", err.message
  ensure
    client_sock&.close
  end

  def test_read_reply_handles_empty_error_message
    ["-error \n", "-error\n"].each do |payload|
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM)
      server_sock.write(payload)
      server_sock.close

      err = assert_raises(EmacsDebug::EmacsServerProtocol::Error) do
        EmacsDebug::EmacsServerProtocol.read_reply(client_sock, 1)
      end
      assert_equal "Emacs server returned an error", err.message
    ensure
      client_sock&.close
    end
  end

  def test_read_reply_ignores_escaped_error_text_in_print_payload
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM)
    server_sock.write("-emacs-pid 1234\n-print \"&-error&_harmless\"&n\n")
    server_sock.flush

    reply = EmacsDebug::EmacsServerProtocol.read_reply(client_sock, 1)
    assert_includes reply, '-print "&-error&_harmless"&n'
  ensure
    client_sock&.close
    server_sock&.close
  end

  def test_read_reply_raises_on_timeout
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM)

    err = assert_raises(EmacsDebug::EmacsServerProtocol::Error) do
      EmacsDebug::EmacsServerProtocol.read_reply(client_sock, 0.05)
    end
    assert_match(/did not respond within/, err.message)
  ensure
    client_sock&.close
    server_sock&.close
  end

  def test_socket_client_sends_trailing_space_before_newline
    with_unix_server("-emacs-pid 99\n-print nil&n\n") do |socket_path, read_received|
      with_env("EMACS_SOCKET_NAME" => socket_path, "EMACS_SERVER_FILE" => nil) do
        reply = EmacsDebug::SocketClient.eval("(+ 1 2)")
        assert_includes reply, "-print nil&n"
      end

      raw = read_received.call
      assert_equal "-eval (+&_1&_2) \n", raw
      assert raw.end_with?(" \n")
    end
  end

  def test_socket_client_raises_on_server_error_reply
    with_unix_server("-emacs-pid 99\n-error emacsclient&_request&_did&_not&_end&_in&_SPC\n") do |socket_path, _read|
      with_env("EMACS_SOCKET_NAME" => socket_path, "EMACS_SERVER_FILE" => nil) do
        err = assert_raises(EmacsDebug::SocketClient::Error) do
          EmacsDebug::SocketClient.eval("(+ 1 2)")
        end
        assert_equal "emacsclient request did not end in SPC", err.message
      end
    end
  end

  def test_tcp_client_sends_auth_and_trailing_space_before_newline
    with_tcp_server("-emacs-pid 99\n-print nil&n\n", auth_key: "secret-key") do |server_file, read_received|
      with_env("EMACS_SERVER_FILE" => server_file, "EMACS_SOCKET_NAME" => nil) do
        reply = EmacsDebug::TcpClient.eval("(+ 1 2)")
        assert_includes reply, "-print nil&n"
      end

      raw = read_received.call
      assert_equal "-auth secret-key -eval (+&_1&_2) \n", raw
      assert raw.end_with?(" \n")
    end
  end

  def test_tcp_client_raises_on_server_error_reply
    with_tcp_server("-error Authentication&_failed\n") do |server_file, _read|
      with_env("EMACS_SERVER_FILE" => server_file, "EMACS_SOCKET_NAME" => nil) do
        err = assert_raises(EmacsDebug::TcpClient::Error) do
          EmacsDebug::TcpClient.eval("(+ 1 2)")
        end
        assert_equal "Authentication failed", err.message
      end
    end
  end

  def test_eval_lisp_falls_back_to_tcp_when_socket_returns_error
    with_unix_server("-emacs-pid 1\n-error broken&_socket\n") do |socket_path, _read_unix|
      with_tcp_server("-emacs-pid 2\n-print nil&n\n", auth_key: "fallback-key") do |server_file, read_tcp|
        with_env("EMACS_SOCKET_NAME" => socket_path, "EMACS_SERVER_FILE" => server_file) do
          EmacsDebug.send(:eval_lisp, "(+ 1 2)")
        end

        assert_equal "-auth fallback-key -eval (+&_1&_2) \n", read_tcp.call
      end
    end
  end
end
