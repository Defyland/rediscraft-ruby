# frozen_string_literal: true

require "rediscraft/application/response"

module Rediscraft
  module Interface
    # The choice of which wire frame a Response maps to is identical for every
    # protocol; only the bytes of each frame differ (a line terminator here, a
    # length-prefixed body there). Owning that routing in one place keeps the two
    # protocols from drifting -- before this, one formatter handled a bare nil and
    # the other did not, and only one spelled out the simple-string case. A
    # protocol includes this module and supplies the terminal encoders below.
    module ResponseFormatting
      def format(response)
        return null_bulk if response.nil?
        unless response.is_a?(Rediscraft::Application::Response)
          raise TypeError, "expected Rediscraft::Application::Response or nil, got #{response.class}"
        end

        case response.kind
        when :error then error_frame(response.payload)
        when :bulk then response.payload.nil? ? null_bulk : bulk_frame(response.payload)
        when :integer then integer_frame(response.payload)
        when :array then array_frame(response.payload)
        when :simple then simple_frame(response.payload)
        else
          raise ArgumentError, "unknown response kind: #{response.kind.inspect}"
        end
      end
    end
  end
end
