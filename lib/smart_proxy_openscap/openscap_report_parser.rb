# encoding=utf-8
require 'tempfile'

module Proxy::OpenSCAP
  class Parse
    include ::Proxy::Log
    include ::Proxy::Util

    def initialize(arf_data)
      @file = Tempfile.new('arf')
      raise StandardError, "Cannot create file to store report data" unless File.exist? @file
      @file.write arf_data
    end

    def as_json
      json_file = Tempfile.new('arf-json')
      shell_command "oscap_bindings #{@file.path} #{json_file.path}"
      json = File.read(json_file)
      json_file.close
      @file.close
      json
    end
  end
end
