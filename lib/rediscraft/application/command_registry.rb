# frozen_string_literal: true

module Rediscraft
  module Application
    class CommandRegistry
      Spec = Data.define(:name, :arity, :durable) do
        def valid_arity?(parts)
          parts.length == arity
        end
      end

      SPECS_BY_NAME = [
        Spec.new(name: "PING", arity: 1, durable: false),
        Spec.new(name: "SET", arity: 3, durable: true),
        Spec.new(name: "GET", arity: 2, durable: false),
        Spec.new(name: "DEL", arity: 2, durable: true),
        Spec.new(name: "EXISTS", arity: 2, durable: false),
        Spec.new(name: "EXPIRE", arity: 3, durable: true),
        Spec.new(name: "TTL", arity: 2, durable: false),
        Spec.new(name: "PERSIST", arity: 2, durable: true)
      ].each_with_object({}) { |spec, specs| specs[spec.name] = spec }.freeze

      def self.public_names
        SPECS_BY_NAME.keys
      end

      def self.normalize(command)
        command&.upcase
      end

      def self.fetch(command)
        SPECS_BY_NAME[normalize(command)]
      end

      def self.valid_arity?(parts)
        spec = fetch(parts.first)
        spec&.valid_arity?(parts) || false
      end

      def self.durable?(command)
        fetch(command)&.durable || false
      end

      def self.durable_parts_for(parts, clock:)
        spec = fetch(parts.first)
        return nil unless spec&.durable
        return nil unless spec.valid_arity?(parts)

        case spec.name
        when "SET", "DEL", "PERSIST"
          parts
        when "EXPIRE"
          ttl_seconds = parse_non_negative_integer(parts[2])
          return nil if ttl_seconds.nil?

          ["EXPIREAT", parts[1], (clock.call + ttl_seconds).to_f.to_s]
        end
      end

      def self.parse_non_negative_integer(value)
        Integer(value, 10).then { |number| number.negative? ? nil : number }
      rescue ArgumentError
        nil
      end
    end
  end
end
