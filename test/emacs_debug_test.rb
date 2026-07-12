require "test_helper"

class EmacsDebugTest < Minitest::Test
  def teardown
    EmacsDebug.app_root = nil
    EmacsDebug.container_root = nil
    EmacsDebug.host_root = nil
  end

  def test_config_accessors_delegate_to_configuration
    EmacsDebug.host_root = "/Users/me/myapp/"
    assert_equal "/Users/me/myapp/", EmacsDebug.host_root
    assert_equal "/Users/me/myapp/", EmacsDebug.configuration.host_root
  end

  def test_host_root_falls_back_to_env
    EmacsDebug.host_root = nil
    ENV["EMACS_DEBUG_HOST_ROOT"] = "/from/env/"
    assert_equal "/from/env/", EmacsDebug.host_root
  ensure
    ENV.delete("EMACS_DEBUG_HOST_ROOT")
  end
end

class ConfigurationTest < Minitest::Test
  def setup
    @config = EmacsDebug::Configuration.new
  end

  def test_resolve_path_translates_container_path_to_host_path
    @config.container_root = "/app/"
    @config.host_root = "/Users/me/myapp/"
    assert_equal "/Users/me/myapp/models/user.rb",
                 @config.resolve_path("/app/models/user.rb")
  end

  def test_resolve_path_is_identity_without_host_root
    @config.container_root = "/app/"
    @config.host_root = nil
    assert_equal "/app/models/user.rb",
                 @config.resolve_path("/app/models/user.rb")
  end

  def test_resolve_path_is_identity_for_paths_outside_container_root
    @config.container_root = "/app/"
    @config.host_root = "/Users/me/myapp/"
    assert_equal "/usr/lib/ruby/socket.rb",
                 @config.resolve_path("/usr/lib/ruby/socket.rb")
  end
end
