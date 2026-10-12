# frozen_string_literal: true

# Entry point named after the gem. `require "microsandbox"` resolves to
# whichever installed gem ships that file first, and the separate
# `microsandbox` gem on RubyGems ships one too; outside Bundler,
# `require "microsandbox-rb"` always loads this gem.
require_relative "microsandbox"
