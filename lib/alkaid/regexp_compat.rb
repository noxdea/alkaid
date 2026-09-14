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
        expression = super(*arguments)
        Regexp::TIMEOUTS[expression] = timeout
        expression
      end
    end)
  end

  module Alkaid
    def self.with_regexp_timeout(expression)
      expression.timeout ? Timeout.timeout(expression.timeout, Regexp::TimeoutError) { yield } : yield
    end
  end
else
  module Alkaid
    def self.with_regexp_timeout(_expression) = yield
  end
end
