# frozen_string_literal: true

module Rediscraft
  module Application
    Response = Data.define(:status, :payload) do
      def self.ok(payload)
        new(status: :ok, payload: payload)
      end

      def self.error(payload)
        new(status: :error, payload: payload)
      end
    end
  end
end
