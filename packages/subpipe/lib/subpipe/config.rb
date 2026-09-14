# frozen_string_literal: true

require "json"
require "fileutils"

module Subpipe
  # Global + show-level settings for mentor power-user knobs.
  #
  # Global:  ~/.config/subpipe/config.json
  # Show:    Show/subpipe-project.json → mentor.* (wins over global)
  #
  #   mentor.propagate_on_accept: ask | auto | off  (default: ask)
  module Config
    module_function

    GLOBAL_PATH = File.join(Dir.home, ".config", "subpipe", "config.json").freeze
    PROPAGATE_MODES = %w[ask auto off].freeze
    DEFAULTS = {
      "mentor" => {
        "propagate_on_accept" => "ask"
      }
    }.freeze

    def global_path
      GLOBAL_PATH
    end

    def load_global
      if File.file?(GLOBAL_PATH)
        deep_merge(DEFAULTS, JSON.parse(File.read(GLOBAL_PATH)))
      else
        deep_merge(DEFAULTS, {})
      end
    rescue JSON::ParserError
      deep_merge(DEFAULTS, {})
    end

    def save_global!(hash)
      FileUtils.mkdir_p(File.dirname(GLOBAL_PATH))
      File.write(GLOBAL_PATH, JSON.pretty_generate(hash) + "\n")
      GLOBAL_PATH
    end

    def get(dotted_key)
      walk(load_global, dotted_key.split("."))
    end

    def set!(dotted_key, value)
      parts = dotted_key.split(".")
      Subpipe.abort!("config key required") if parts.empty?

      data = load_global
      node = data
      parts[0..-2].each do |p|
        node[p] = {} unless node[p].is_a?(Hash)
        node = node[p]
      end
      node[parts.last] = coerce_value(dotted_key, value)
      save_global!(data)
      get(dotted_key)
    end

    def propagate_on_accept(out_dir, context = nil)
      mode = DEFAULTS.dig("mentor", "propagate_on_accept")
      g = load_global.dig("mentor", "propagate_on_accept")
      mode = g if g && !g.to_s.empty?
      meta = Feedback.load_project_meta(out_dir, context)
      s = meta.dig("mentor", "propagate_on_accept")
      mode = s if s && !s.to_s.empty?
      mode = mode.to_s.strip.downcase
      PROPAGATE_MODES.include?(mode) ? mode : "ask"
    end

    def coerce_value(dotted_key, value)
      v = value.to_s
      if dotted_key == "mentor.propagate_on_accept"
        v = v.strip.downcase
        Subpipe.abort!("propagate_on_accept must be one of: #{PROPAGATE_MODES.join(', ')}") unless PROPAGATE_MODES.include?(v)
        return v
      end
      v
    end

    def walk(hash, parts)
      cur = hash
      parts.each do |p|
        return nil unless cur.is_a?(Hash)

        cur = cur[p]
      end
      cur
    end

    def deep_merge(base, over)
      base.merge(over) do |_k, a, b|
        a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
      end
    end
  end
end
