require "test_helper"
require "rediscraft/application/response"
require "rediscraft/interface/resp2_protocol"

class Resp2ProtocolTest < Minitest::Test
  def setup
    @protocol = Rediscraft::Interface::Resp2Protocol.new
  end

  def test_consume_parses_simple_string
    assert_equal [["PING"], ""], @protocol.consume("+PING\r\n")
  end

  def test_consume_parses_error_as_token_for_parser_coverage
    assert_equal [["ERR unsupported"], ""], @protocol.consume("-ERR unsupported\r\n")
  end

  def test_consume_parses_integer
    assert_equal [["42"], ""], @protocol.consume(":42\r\n")
  end

  def test_consume_parses_bulk_string
    assert_equal [["hello\r\nworld"], ""], @protocol.consume("$12\r\nhello\r\nworld\r\n")
  end

  def test_consume_parses_array_command_and_returns_rest
    assert_equal [["SET", "name", "Ada"], ""],
      @protocol.consume("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$3\r\nAda\r\n")
  end

  def test_consume_returns_nil_on_empty_buffer
    assert_nil @protocol.consume("")
  end

  def test_consume_returns_nil_on_partial_frame
    assert_nil @protocol.consume("*3\r\n$3\r\nSET\r\n$4\r\nna")
  end

  def test_consume_keeps_trailing_bytes_of_the_next_frame
    parts, rest = @protocol.consume("*1\r\n$4\r\nPING\r\n*1\r\n$4\r\nQUIT\r\n")

    assert_equal ["PING"], parts
    assert_equal "*1\r\n$4\r\nQUIT\r\n", rest
  end

  def test_consume_rejects_null_bulk_in_command
    assert_raises(Rediscraft::Interface::ProtocolError) do
      @protocol.consume("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$-1\r\n")
    end
  end

  def test_consume_raises_protocol_error_on_invalid_bulk_terminator
    assert_raises(Rediscraft::Interface::ProtocolError) do
      @protocol.consume("$3\r\nabcXX")
    end
  end

  def test_formats_application_responses
    assert_equal "+PONG\r\n", @protocol.format(Rediscraft::Application::Response.simple("PONG"))
    assert_equal "$3\r\nAda\r\n", @protocol.format(Rediscraft::Application::Response.bulk("Ada"))
    assert_equal "$-1\r\n", @protocol.format(Rediscraft::Application::Response.bulk(nil))
    assert_equal ":1\r\n", @protocol.format(Rediscraft::Application::Response.integer(1))
    assert_equal "-ERR unknown command\r\n", @protocol.format(Rediscraft::Application::Response.error("ERR unknown command"))
  end
end
