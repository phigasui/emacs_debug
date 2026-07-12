require "test_helper"
require "socket"

class EmacsServerProtocolTest < Minitest::Test
  Protocol = EmacsDebug::EmacsServerProtocol

  def test_quote_escapes_special_characters
    assert_equal "&&", Protocol.quote("&")
    assert_equal "&-", Protocol.quote("-")
    assert_equal "&n", Protocol.quote("\n")
    assert_equal "&_", Protocol.quote(" ")
  end

  def test_quote_leaves_ordinary_characters_untouched
    assert_equal "abcDEF123", Protocol.quote("abcDEF123")
  end

  def test_quote_escapes_ampersand_before_others
    # "& " must become "&&&_", not "&&_" (ampersand escaped first).
    assert_equal "&&&_", Protocol.quote("& ")
  end

  def test_read_reply_returns_once_print_line_arrives
    reader, writer = UNIXSocket.pair
    writer.write("-print foo\n")
    writer.close

    assert_equal "-print foo\n", Protocol.read_reply(reader, 5)
  ensure
    reader.close
  end

  def test_read_reply_returns_on_error_line
    reader, writer = UNIXSocket.pair
    writer.write("-error something\n")
    writer.close

    assert_includes Protocol.read_reply(reader, 5), "-error "
  ensure
    reader.close
  end

  def test_read_reply_returns_on_eof
    reader, writer = UNIXSocket.pair
    writer.write("partial data without terminator")
    writer.close

    assert_equal "partial data without terminator", Protocol.read_reply(reader, 5)
  ensure
    reader.close
  end

  def test_read_reply_handles_split_arrival
    reader, writer = UNIXSocket.pair
    writer.write("-pri")
    reader_thread = Thread.new { Protocol.read_reply(reader, 5) }
    # Give the reader a moment to block, then complete the line.
    Thread.pass
    writer.write("nt done\n")
    writer.close

    assert_equal "-print done\n", reader_thread.value
  ensure
    reader.close
  end

  def test_read_reply_returns_without_hanging_on_a_silent_server
    reader, writer = UNIXSocket.pair
    # Never write anything; keep writer open so there's no EOF. When
    # IO.select itself times out (no data at all), read_reply returns the
    # buffer accumulated so far ("") rather than blocking forever. The
    # timeout Error path only fires when data dribbles in past the deadline.

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Protocol.read_reply(reader, 0.1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal "", result
    assert_operator elapsed, :<, 1.0
  ensure
    reader.close
    writer.close
  end
end
