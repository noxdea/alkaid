# frozen_string_literal: true

require_relative "alkaid/version"

module Alkaid
  class Error < StandardError; end

  module Value
    module_function

    def define(*members)
      return Data.define(*members) if defined?(Data)

      Struct.new(*members) do
        members.each { |member| undef_method("#{member}=") }

        def initialize(*values, **keywords)
          if keywords.empty?
            raise ArgumentError, "wrong number of arguments" unless values.length == self.class.members.length

            super(*values)
          else
            raise ArgumentError, "cannot mix positional and keyword arguments" unless values.empty?

            missing = self.class.members - keywords.keys
            unknown = keywords.keys - self.class.members
            raise ArgumentError, "missing keyword: #{missing.first.inspect}" unless missing.empty?
            raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

            super(*self.class.members.map { |member| keywords.fetch(member) })
          end
          freeze
        end

        def with(**changes)
          return self if changes.empty?

          unknown = changes.keys - self.class.members
          raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

          self.class.new(**to_h.merge(changes))
        end
      end
    end
  end

  Match = Value.define(:path, :line_number, :byte_offset, :line, :ranges)
  Progress = Value.define(:files_scanned, :bytes_scanned, :matches)
  private_constant :Value
end

require_relative "alkaid/regexp_compat"
require_relative "alkaid/match_data_compat"
require_relative "alkaid/walker"
require_relative "alkaid/search"
