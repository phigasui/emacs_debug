# emacs_debug

*English · [日本語](README.ja.md)*

Debug Ruby applications with Emacs integration. When something interesting
happens in your Ruby process, `emacs_debug` opens the relevant source file in
a running Emacs, highlights the triggering line, and shows debug output or
the exception message in a dedicated buffer — no `binding.pry` /
`byebug` session required.

It talks to Emacs directly — over its Unix-domain socket when Emacs is on
the same machine, or over its TCP server when it isn't (e.g. reaching a
host Emacs from inside Docker) — implementing Emacs's own server protocol
in pure Ruby. No `emacsclient` binary is required or used, on either
path.

## Requirements

- Ruby >= 3.1
- A running Emacs with the server started (`M-x server-start` or
  `(server-start)` in your init file)

## Installation

Add to your Gemfile:

```ruby
gem "emacs_debug"
```

Or install directly from this repository (not yet published to
RubyGems.org):

```ruby
gem "emacs_debug", git: "https://github.com/phigasui/emacs_debug"
```

## Usage

```ruby
require "emacs_debug"

EmacsDebug.debug("hello from Ruby") # opens the call site in Emacs, shows the text in *Debug*
```

```ruby
begin
  raise "boom"
rescue => e
  EmacsDebug.open_error(e) # opens the first in-app backtrace frame, shows the message in *Error*
end
```

`EmacsDebug.available?` reports whether Emacs can currently be reached (a
local socket or a TCP server file exists), so it's safe to call `debug` /
`open_error` unconditionally — they're no-ops when Emacs isn't reachable.

### Configuration

| Setting | Default | Purpose |
| --- | --- | --- |
| `EmacsDebug.app_root=` | `Rails.root/app/` when Rails is defined | Restricts `open_error` to backtrace frames under this path |
| `EmacsDebug.container_root=` | `Rails.root/` when Rails is defined | The checkout root as seen by *this* process (e.g. `/app/` in a container) |
| `EmacsDebug.host_root=` | `ENV["EMACS_DEBUG_HOST_ROOT"]` | The same checkout's root as seen by the Emacs process, used to translate container paths to host paths |

`container_root` / `host_root` only matter when Ruby runs somewhere other
than where Emacs runs (typically: Ruby in Docker, Emacs on the host).

### Customizing in Emacs (`init.el`)

`emacs_debug` works out of the box with zero Emacs-side configuration. If you want to customize how files are opened, how lines are highlighted (e.g. for dark themes), or how the output buffers behave, you can set the following variables in your `init.el`:

| Emacs variable | Default | Purpose |
| --- | --- | --- |
| `emacs-debug-highlight-face` | `'(:background "#ffff00")` | Face symbol or plist applied to the highlighted line overlay (previous `emacs-debug` overlays in the buffer are automatically cleared before adding a new one) |
| `emacs-debug-open-file-function` | `nil` (uses `find-file` + overlay) | Function called as `(funcall emacs-debug-open-file-function file line)` to open and highlight the target location |
| `emacs-debug-buffer-mode` | `#'special-mode` | Major mode function called in the `*Debug*` / `*Error*` buffer |
| `emacs-debug-display-buffer-function` | `nil` (uses `get-buffer-create` + `display-buffer`) | Function called as `(funcall emacs-debug-display-buffer-function buf-name file line text)` to render debug/error output |

Example `init.el` configuration:

```elisp
;; Use your theme's built-in `highlight' face (or a custom dark-friendly plist)
(setq emacs-debug-highlight-face 'highlight)

;; Or customize how the source file is opened (e.g. other window + pulse.el)
(setq emacs-debug-open-file-function
      (lambda (file line)
        (find-file-other-window file)
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter)
        (pulse-momentary-highlight-one-line (point))))
```

## Rails integration

Rails' exception page skips your usual `raise` / `rescue` code path, so hook
into `ActionDispatch::DebugExceptions` instead. Add
`config/initializers/emacs_debug.rb`:

```ruby
if defined?(EmacsDebug)
  ActionDispatch::DebugExceptions.register_interceptor do |_request, exception|
    EmacsDebug.open_error(exception)
  end
end
```

This opens the offending file at the exception's origin and shows the error
message in Emacs every time a request raises in development.

## Running Ruby in Docker, Emacs on the host

If your Rails app runs inside Docker but Emacs runs on your host machine, a
Unix-domain socket won't reach across the container boundary. Point
`emacs_debug` at a TCP server instead:

1. On the host, before starting Emacs:

   ```elisp
   (setq server-use-tcp t)
   (setq server-host "0.0.0.0") ; or a more restrictive bind address
   (server-start)
   ```

2. Rewrite the server file so the container can reach the host via
   `host.docker.internal`:

   ```sh
   bin/emacs-server-file-for-docker
   ```

   This writes `~/.emacs.d/server/docker` alongside the real server file
   (pass `HOST`, `SOURCE`, `DEST` as arguments to override the defaults —
   see the script header for details).

3. Mount that file into the container and point `EMACS_SERVER_FILE` at it:

   ```sh
   docker run --rm \
     -v ~/.emacs.d/server/docker:/server/docker:ro \
     -e EMACS_SERVER_FILE=/server/docker \
     -e EMACS_DEBUG_HOST_ROOT=/Users/me/myapp/ \
     your-app-image
   ```

   `EMACS_DEBUG_HOST_ROOT` (see `EmacsDebug.host_root=`) lets `emacs_debug`
   translate container paths (e.g. `/app/models/user.rb`) to the matching
   path on the host filesystem, so Emacs opens a file it can actually find.

No `emacsclient` binary is needed in the container image — `emacs_debug`
speaks the TCP server protocol directly.

## Verifying the Docker setup

`docker/verify.rb` and the accompanying `Dockerfile` (which doesn't
install `emacsclient` at all) exercise both scenarios:

```sh
# no server reachable
docker build -t emacs_debug_verify .
docker run --rm emacs_debug_verify

# pointed at a host TCP server
docker run --rm -e EMACS_SERVER_FILE=/server/docker \
  -v ~/.emacs.d/server/docker:/server/docker:ro \
  emacs_debug_verify
```
