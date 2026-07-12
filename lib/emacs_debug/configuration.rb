module EmacsDebug
  # Holds the handful of roots that tell emacs_debug which frames belong to
  # the app and how to translate a path from this process's filesystem to
  # the one Emacs sees. Kept apart from the public API so emacs_debug.rb is
  # just `debug` / `open_error` / dispatch.
  class Configuration
    attr_writer :app_root, :container_root, :host_root

    # Backtrace frames under this root are the ones open_error jumps to.
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

    # Rewrites a path from this process's view to the Emacs process's view.
    # A no-op unless both roots are set and the path actually lives under
    # container_root (files outside the checkout, e.g. gems, are left be).
    def resolve_path(file)
      return file unless host_root && container_root && file.start_with?(container_root)

      File.join(host_root, file.delete_prefix(container_root))
    end
  end
end
