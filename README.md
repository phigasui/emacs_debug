# emacs_debug

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
