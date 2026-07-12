# Verification image for the emacs_debug gem.
#
# Build without emacsclient (reproduces the original Docker bug report):
#   docker build -t emacs_debug_verify .
#   docker run --rm emacs_debug_verify
#
# Build with emacsclient present (binary exists but no server to reach):
#   docker build --build-arg WITH_EMACSCLIENT=true -t emacs_debug_verify_with .
#   docker run --rm emacs_debug_verify_with
#
# Build with emacsclient present and pointed at a host TCP server:
#   docker run --rm -e EMACS_SERVER_FILE=/server/docker \
#     -v ~/.emacs.d/server/docker:/server/docker:ro \
#     emacs_debug_verify_with
FROM ruby:3.3-slim

ARG WITH_EMACSCLIENT=false

RUN if [ "$WITH_EMACSCLIENT" = "true" ]; then \
      apt-get update && \
      apt-get install -y --no-install-recommends emacs-nox && \
      rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /app

COPY emacs_debug.gemspec Gemfile ./
COPY lib ./lib

RUN bundle install

COPY docker ./docker

CMD ["bundle", "exec", "ruby", "docker/verify.rb"]
