require "test_helper"

class LispTest < Minitest::Test
  Lisp = EmacsDebug::Lisp

  def test_escape_handles_backslash_quote_and_newline
    assert_equal 'a\\\\b\\"c\\nd', Lisp.escape(%(a\\b"c\nd))
  end

  def test_string_wraps_in_quotes_and_escapes
    assert_equal %("a\\"b"), Lisp.string(%(a"b))
  end

  # Regression tests for the escaping bug: file paths and buffer names used
  # to be embedded raw, so a `"` or `\` in a path corrupted the Lisp.
  def test_open_and_highlight_escapes_quotes_in_path
    lisp = Lisp.open_and_highlight('/tmp/we"ird/user.rb', 42)
    assert_includes lisp, '(find-file "/tmp/we\\"ird/user.rb")'
  end

  def test_open_and_highlight_escapes_backslashes_in_path
    lisp = Lisp.open_and_highlight('C:\\app\\user.rb', 42)
    assert_includes lisp, '(find-file "C:\\\\app\\\\user.rb")'
  end

  def test_open_and_highlight_coerces_line_to_integer
    lisp = Lisp.open_and_highlight("/tmp/user.rb", "42")
    assert_includes lisp, "(forward-line (1- 42))"
  end

  def test_open_and_highlight_rejects_non_integer_line
    assert_raises(ArgumentError) { Lisp.open_and_highlight("/tmp/user.rb", "not-a-line") }
  end

  def test_display_in_buffer_escapes_all_embedded_values
    lisp = Lisp.display_in_buffer('*Deb"ug*', '/tmp/we"ird.rb', 7, %(text with "quote"))
    assert_includes lisp, '(get-buffer-create "*Deb\\"ug*")'
    # The header carries the (escaped) file path.
    assert_includes lisp, 'we\\"ird.rb:7'
    assert_includes lisp, 'text with \\"quote\\"'
  end
end
