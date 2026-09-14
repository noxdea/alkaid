# frozen_string_literal: true

require_relative "../../alkaid"

Alkaid.const_get(:SearchWorker, false).run
