# frozen_string_literal: true

module Rediscraft
  module Application
    Response = Data.define(:status, :payload, :kind) do
      def self.simple(payload)
        new(status: :ok, payload: payload, kind: :simple)
      end

      def self.bulk(payload)
        new(status: :ok, payload: payload, kind: :bulk)
      end

      def self.integer(payload)
        new(status: :ok, payload: payload, kind: :integer)
      end

      def self.error(payload)
        new(status: :error, payload: payload, kind: :error)
      end
    end
  end
end
