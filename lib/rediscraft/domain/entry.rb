# frozen_string_literal: true

module Rediscraft
  module Domain
    Entry = Data.define(:value, :expires_at) do
      def expired?(now)
        !expires_at.nil? && expires_at <= now
      end
    end
  end
end
