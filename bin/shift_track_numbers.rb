#!/usr/bin/env ruby

# Check if increment value is provided
if ARGV.empty?
  puts "Usage: #{$0} <number>"
  exit 1
end

increment = ARGV[0].to_i
directory = Dir.pwd

Dir.foreach(directory) do |filename|
  path = File.join(directory, filename)
  next if File.directory?(path)

  if filename =~ /\A(\d+)(.*)/i
    prefix_num = $1.to_i
    rest_of_name = $2
    new_num = prefix_num + increment
    num_width = $1.length
    formatted_num = sprintf("%0#{num_width}d", new_num)
    new_filename = "#{formatted_num}#{rest_of_name}"
    new_path = File.join(directory, new_filename)

    File.rename(path, new_path)
    puts "#{filename} -> #{new_filename}"
  end
end

