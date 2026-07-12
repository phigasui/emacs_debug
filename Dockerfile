# Verification image for the emacs_debug gem. No emacsclient binary is
# installed here: SocketClient/TcpClient talk to Emacs's server directly.
#
# No server reachable (debug/open_error become no-ops):
#   docker build -t emacs_debug_verify .
#   docker run --rm emacs_debug_verify
#
# Pointed at a host TCP server:
#   docker run --rm -e EMACS_SERVER_FILE=/server/docker \
#     -v ~/.emacs.d/server/docker:/server/docker:ro \
#     emacs_debug_verify
FROM ruby:3.3-slim

WORKDIR /app

COPY emacs_debug.gemspec Gemfile ./
COPY lib ./lib

RUN bundle install

COPY docker ./docker

CMD ["bundle", "exec", "ruby", "docker/verify.rb"]
