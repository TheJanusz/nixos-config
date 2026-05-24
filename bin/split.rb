#!/usr/bin/env ruby

require 'rubycue'
require 'taglib'

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
raise "Chapter number mismatch. Cuesheet: #{cuesheet.songs.size}, Found files: #{output_files.size}" unless cuesheet.songs.size == output_files.size

output_files.each_with_index do |file, index|
  TagLib::MPEG::File.open(file) do |f|
    tag = f.id3v2_tag
    tag.artist = cuesheet.performer
    tag.title = cuesheet.songs[index][:title]
    tcom_frame = TagLib::ID3v2::TextIdentificationFrame.new('TCOM', TagLib::String::UTF8)
    tcom_frame.text = cuesheet.songs.dig(index, :performer)
    tag.add_frame(tcom_frame)
    tag.track = index + 1

    cover_filename = File.basename(cuesheet.file, ".*") + ".jpeg"
    cover = File.open(cover_filename, 'rb') { it.read }
    apic = TagLib::ID3v2::AttachedPictureFrame.new
    apic.mime_type = 'image/jpeg' # TODO: Get this dynamically from the file itself maybe in case they change formats
    apic.type = TagLib::ID3v2::AttachedPictureFrame::FrontCover
    apic.description = "Cover"
    apic.picture = cover
    tag.add_frame(apic)
    f.save

    extension = File.extname(file)
    new_filename = "#{cuesheet.songs.dig(index, :title)}.#{extension}"
    File.rename(file, new_filename)
  end
end
# end
