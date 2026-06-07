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

  def test_formats_errors_with_error_prefix
    response = Rediscraft::Application::Response.error("ERR unknown command")

    assert_equal "-ERR unknown command\n", @protocol.format(response)
  end
end
