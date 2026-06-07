require "test_helper"
require "stringio"
require "rediscraft/application/response"
require "rediscraft/interface/resp2_protocol"

class Resp2ProtocolTest < Minitest::Test
  def setup
    @protocol = Rediscraft::Interface::Resp2Protocol.new
  end

  def test_parses_simple_string
    assert_equal ["PING"], @protocol.read_request(StringIO.new("+PING\r\n"))
  end

  def test_parses_error_as_token_for_parser_coverage
    assert_equal ["ERR unsupported"], @protocol.read_request(StringIO.new("-ERR unsupported\r\n"))
  end

  def test_parses_integer
    assert_equal ["42"], @protocol.read_request(StringIO.new(":42\r\n"))
  end

  def test_parses_bulk_string
    assert_equal ["hello\r\nworld"], @protocol.read_request(StringIO.new("$12\r\nhello\r\nworld\r\n"))
  end

  def test_parses_array_command
    payload = "*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$3\r\nAda\r\n"

    assert_equal ["SET", "name", "Ada"], @protocol.read_request(StringIO.new(payload))
  end

  def test_parses_null_bulk_as_nil
    assert_equal ["SET", "name", nil], @protocol.read_request(StringIO.new("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$-1\r\n"))
  end

  def test_formats_application_responses
    assert_equal "+PONG\r\n", @protocol.format(Rediscraft::Application::Response.simple("PONG"))
    assert_equal "$3\r\nAda\r\n", @protocol.format(Rediscraft::Application::Response.bulk("Ada"))
    assert_equal "$-1\r\n", @protocol.format(Rediscraft::Application::Response.bulk(nil))
    assert_equal ":1\r\n", @protocol.format(Rediscraft::Application::Response.integer(1))
    assert_equal "-ERR unknown command\r\n", @protocol.format(Rediscraft::Application::Response.error("ERR unknown command"))
  end

  def test_rejects_incomplete_bulk_string
    assert_nil @protocol.read_request(StringIO.new("$5\r\nabc"))
  end
end
