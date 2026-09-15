# frozen_string_literal: true

unless Regexp.respond_to?(:timeout)
  require "timeout"

  class Regexp
    TimeoutError = Class.new(StandardError) unless const_defined?(:TimeoutError, false)
    TIMEOUTS = ObjectSpace::WeakMap.new unless const_defined?(:TIMEOUTS, false)
  end

  unless Regexp.method_defined?(:timeout)
    class Regexp
      def timeout = TIMEOUTS[self]
    end

    Regexp.singleton_class.prepend(Module.new do
      def new(*arguments, timeout: nil)
        if timeout
          raise TypeError, "timeout must be numeric" unless timeout.is_a?(Numeric)

          timeout = timeout.to_f
          timeout = nil if timeout.nan?
          raise ArgumentError, "invalid timeout" if timeout && !timeout.positive?
        end
        expression = super(*arguments)
        Regexp::TIMEOUTS[expression] = timeout
        expression
      end
    end)
  end

  module Alkaid
    def self.with_regexp_timeout(expression)
      timeout = expression.timeout
      timeout && timeout.finite? ? Timeout.timeout(timeout, Regexp::TimeoutError) { yield } : yield
    end
  end
else
  module Alkaid
    def self.with_regexp_timeout(_expression) = yield
  end
end
