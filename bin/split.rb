#!/usr/bin/env ruby

require 'rubycue'

module Bugfix
  refine RubyCue::Cuesheet do

    def initialize(cuesheet, track_duration=nil)
      @cuesheet = cuesheet
      @reg = {
        :track => %r(TRACK (\d{1,3}) AUDIO),
        :performer => %r(PERFORMER "(.*)"),
        :title => %r(TITLE "(.*)"),
        :index => %r(INDEX \d{1,3} (\d{1,4}):(\d{1,2}):(\d{1,2})),
        :file => %r(FILE "(.*)"),
        :genre => %r(REM GENRE (.*)\b)
      }
      @track_duration = RubyCue::Index.new(track_duration) if track_duration
    end
  end
end

using Bugfix
cue_file = ARGV[0] || 'file.cue'
cuesheet = RubyCue::Cuesheet.new(File.read(cue_file))
cuesheet.parse!

# Extract audio file name from CUE
audio_file = cuesheet.file
raise "Audio file not found" unless File.exist?(audio_file)

# Process tracks
# cuesheet.songs.each_with_index do |song, i|
# start_time = song[:index].to_f
# next_start = cuesheet.songs[i + 1][:index].to_f rescue nil
start_times = cuesheet.songs[1..].map { it[:index].to_f }

# track_num = song[:track].to_s.rjust(2, '0')
# title = song[:title] || 'Unknown Title'
# performer = song[:performer] || 'Unknown Performer'

# output_file = "#{track_num} - #{title}.mp3"

cmd = "ffmpeg -i \"#{audio_file}\""
cmd += " -f segment -segment_times \"#{start_times.join(',')}\""
cmd += " -loglevel quiet -stats"
cmd += " -c copy"
cmd += " output_%03d.mp3" # TODO: Support other extensions

# It's much faster to use -f segment, but it produces numbered files, no metadata/proper file names
system(cmd)

# So after ffmpeg is done we need to do a second sweep to rename and apply metadata
output_files = Dir.glob("output_*.mp3")
puts cuesheet.songs.inspect
# end
