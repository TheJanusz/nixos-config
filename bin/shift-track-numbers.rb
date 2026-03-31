#!/usr/bin/env ruby

require 'fileutils'
require 'optparse'

options = {}
OptionParser.new do |opts|
  opts.on('-f', '--format FORMAT', 'Format of files that should be shifted') { options[:format] = it }
  opts.on('-o', '--output DIRECTORY', 'Output directory') { options[:output] = it }
end.parse!

dirs = ARGV.map do |dir|
  Dir.chdir(dir)
  mapped = { files: Dir.glob("*.#{options[:format]}"), dir: }
  Dir.chdir('../')
  mapped
end

files_count = dirs.sum { it[:files].size }
pp "Renaming #{files_count} files."
rjust_size = files_count.to_s.size

FileUtils.mkdir_p options[:output]

dirs.each_with_object({counter: 0}) do |dir, obj|
  dir[:files].each do |file|
    FileUtils.cp "#{dir[:dir]}/#{file}", "#{options[:output]}/#{file.gsub(/^\d+/, (obj[:counter]+=1).to_s.rjust(rjust_size, '0'))}"
    print '.'
  end
end

