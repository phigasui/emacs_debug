require "test_helper"
require "tmpdir"

class TcpClientTest < Minitest::Test
  Client = EmacsDebug::TcpClient
  Error = EmacsDebug::EmacsServerProtocol::Error

  def setup
    @saved_env = ENV.to_hash.slice(
      "EMACS_SERVER_FILE", "XDG_CONFIG_HOME"
    )
  end

  def teardown
    %w[EMACS_SERVER_FILE XDG_CONFIG_HOME].each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
  end

  def test_server_file_path_uses_absolute_name_when_it_contains_slash
    ENV["EMACS_SERVER_FILE"] = "/mnt/server/docker"
    assert_equal "/mnt/server/docker", Client.server_file_path
  end

  def test_read_server_file_parses_valid_file
    with_server_file("192.168.0.1:12345 6789\n#{'a' * 64}") do |path|
      ENV["EMACS_SERVER_FILE"] = path
      host, port, auth = Client.send(:read_server_file)
      assert_equal "192.168.0.1", host
      assert_equal 12_345, port
      assert_equal "a" * 64, auth
    end
  end

  def test_read_server_file_raises_when_missing
    ENV["EMACS_SERVER_FILE"] = "/no/such/server/file"
    error = assert_raises(Error) { Client.send(:read_server_file) }
    assert_match(/no Emacs server file/, error.message)
  end

  def test_read_server_file_raises_on_missing_auth_line
    with_server_file("192.168.0.1:12345 6789") do |path|
      ENV["EMACS_SERVER_FILE"] = path
      assert_raises(Error) { Client.send(:read_server_file) }
    end
  end

  def test_read_server_file_raises_on_non_integer_port
    with_server_file("192.168.0.1:notaport 6789\n#{'a' * 64}") do |path|
      ENV["EMACS_SERVER_FILE"] = path
      error = assert_raises(Error) { Client.send(:read_server_file) }
      assert_match(/malformed/, error.message)
    end
  end

  def test_read_server_file_raises_on_missing_port
    with_server_file("192.168.0.1\n#{'a' * 64}") do |path|
      ENV["EMACS_SERVER_FILE"] = path
      error = assert_raises(Error) { Client.send(:read_server_file) }
      assert_match(/malformed/, error.message)
    end
  end

  def test_available_is_false_without_a_server_file
    ENV["EMACS_SERVER_FILE"] = "/no/such/server/file"
    refute Client.available?
  end

  private

  def with_server_file(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "server")
      File.write(path, contents)
      yield path
    end
  end
end
