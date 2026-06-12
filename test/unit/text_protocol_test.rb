require "test_helper"
require "rediscraft/interface/text_protocol"

class TextProtocolTest < Minitest::Test
  def setup
    @protocol = Rediscraft::Interface::TextProtocol.new
  end

  def test_parses_whitespace_separated_command
    assert_equal ["SET", "name", "Ada"], @protocol.parse("SET name Ada\n")
  end

  def test_keeps_remaining_text_as_set_value
    assert_equal ["SET", "quote", "hello world"], @protocol.parse("SET quote hello world\n")
  end

  def test_formats_nil_as_null
    assert_equal "$-1\n", @protocol.format(nil)
  end

  def test_rejects_non_response_objects_instead_of_hiding_them_as_null
    assert_raises(TypeError) { @protocol.format("oops") }
  end

  def test_rejects_unknown_response_kinds_instead_of_formatting_them_as_simple
    response = Rediscraft::Application::Response.new(status: :ok, payload: "oops", kind: :mystery)

    assert_raises(ArgumentError) { @protocol.format(response) }
  end

  def test_formats_errors_with_error_prefix
    response = Rediscraft::Application::Response.error("ERR unknown command")

    assert_equal "-ERR unknown command\n", @protocol.format(response)
  end

  def test_formats_bulk_string_even_when_value_looks_like_status
    response = Rediscraft::Application::Response.bulk("OK")

    assert_equal "$2 OK\n", @protocol.format(response)
  end

  def test_consume_returns_command_and_rest_once_line_is_complete
    assert_equal [["PING"], ""], @protocol.consume("PING\n")
    assert_equal [["SET", "name", "Ada"], "GET name\n"],
      @protocol.consume("SET name Ada\nGET name\n")
  end

  def test_consume_returns_nil_until_a_newline_arrives
    assert_nil @protocol.consume("PIN")
  end

  def test_formats_array_as_count_then_bulk_lines
    response = Rediscraft::Application::Response.array(%w[z ab])

    assert_equal "*2\n$1 z\n$2 ab\n", @protocol.format(response)
  end
end
