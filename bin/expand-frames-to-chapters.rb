#!/usr/bin/env ruby

require "json"
require "open3"
require "tmpdir"
require "fileutils"

# Usage:
#   ruby backdropify.rb input.mkv
#
# Output:
#   input-fixed.mkv
#
# Requirements:
#   ffmpeg
#   ffprobe

input = ARGV[0]

if input.nil?
  abort "Usage: #{File.basename($PROGRAM_NAME)} input.mkv"
end

unless File.file?(input)
  abort "File not found: #{input}"
end

FFMPEG  = ENV.fetch("FFMPEG", "ffmpeg")
FFPROBE = ENV.fetch("FFPROBE", "ffprobe")


def run!(*args)
  puts "+ #{args.map { |a| a.include?(" ") ? "\"#{a}\"" : a }.join(" ")}"

  stdout, stderr, status = Open3.capture3(*args)

  unless status.success?
    warn stderr
    abort "Command failed."
  end

  stdout
end


def ffprobe_json(*args)
  stdout, stderr, status = Open3.capture3(FFPROBE, *args)

  unless status.success?
    warn stderr
    abort "ffprobe failed."
  end

  JSON.parse(stdout)
end


# --------------------------------------------------------------------------
# Probe the source
# --------------------------------------------------------------------------

info = ffprobe_json(
  "-v", "error",
  "-print_format", "json",
  "-show_streams",
  "-show_chapters",
  input
)

streams = info.fetch("streams")
chapters = info.fetch("chapters", [])

abort "No chapters found." if chapters.empty?

video_streams = streams.select { |s| s["codec_type"] == "video" }

unless video_streams.length == 1
  abort "Expected exactly one video stream, found #{video_streams.length}."
end

video_stream = video_streams.first

audio_streams = streams.select { |s| s["codec_type"] == "audio" }

abort "No audio streams found." if audio_streams.empty?

puts
puts "Input: #{input}"
puts "Video: #{video_stream["codec_name"]} " \
     "#{video_stream["width"]}x#{video_stream["height"]}"
puts "Chapters: #{chapters.length}"
puts "Audio streams: #{audio_streams.length}"


# --------------------------------------------------------------------------
# Count the actual video frames.
#
# We deliberately count decoded frames rather than trusting the container's
# NUMBER_OF_FRAMES tag or duration.
# --------------------------------------------------------------------------

puts
puts "Counting video frames..."

frame_count_output = run!(
  FFPROBE,
  "-v", "error",
  "-select_streams", "v:0",
  "-count_frames",
  "-show_entries", "stream=nb_read_frames",
  "-of", "default=noprint_wrappers=1:nokey=1",
  input
).strip

frame_count = Integer(frame_count_output)

puts "Video frames: #{frame_count}"
puts "Chapters:     #{chapters.length}"

if frame_count != chapters.length
  abort <<~ERROR

    ERROR: number of video frames does not match number of chapters.

      Video frames : #{frame_count}
      Chapters     : #{chapters.length}

    Nothing has been modified.
  ERROR
end


# --------------------------------------------------------------------------
# Get chapter start times.
# --------------------------------------------------------------------------

chapter_starts = chapters.map do |chapter|
  Float(chapter.fetch("start_time"))
end

# The chapters are assumed to be correct, so we don't perform additional
# validation here.


# --------------------------------------------------------------------------
# Determine the end of the album.
#
# Use the longest audio stream. This is preferable to using the broken
# video's duration.
# --------------------------------------------------------------------------

audio_durations = audio_streams.filter_map do |stream|
  stream["duration"]&.to_f
end

album_duration = chapters.max do |chapter|
  Float(chapter.fetch("end_time"))
end["end_time"].to_f

unless album_duration
  album_duration = info.dig("format", "duration")&.to_f
end
pp album_duration

abort "Unable to determine album duration." unless album_duration

puts
puts format("Album duration: %.3f seconds", album_duration)


# --------------------------------------------------------------------------
# Calculate how long each backdrop should be displayed.
# --------------------------------------------------------------------------

durations = chapter_starts.each_with_index.map do |start_time, i|
  end_time =
    if i + 1 < chapter_starts.length
      chapter_starts[i + 1]
    else
      album_duration
    end

  end_time - start_time
end


# --------------------------------------------------------------------------
# Extract the frames sequentially.
#
# IMPORTANT:
# We do NOT seek to chapter timestamps.
#
# The source video contains one frame per backdrop. Frame order is therefore
# the mapping:
#
#   frame 1 -> chapter 1
#   frame 2 -> chapter 2
#   ...
#
# PNG is used as a lossless intermediate.
# --------------------------------------------------------------------------

Dir.mktmpdir("backdropify-") do |tmp|

  frames_dir = File.join(tmp, "frames")
  FileUtils.mkdir_p(frames_dir)

  frame_pattern = File.join(frames_dir, "frame-%06d.png")

  puts
  puts "Extracting #{frame_count} frames..."

  run!(
    FFMPEG,
    "-hide_banner",
    "-loglevel", "error",
    "-i", input,
    "-map", "0:v:0",
    "-fps_mode", "passthrough",
    "-vsync", "0",
    "-start_number", "1",
    "-c:v", "png",
    frame_pattern
  )

  frames = Dir.glob(File.join(frames_dir, "frame-*.png")).sort

  if frames.length != frame_count
    abort <<~ERROR

      ERROR: FFmpeg extracted #{frames.length} frames,
      but ffprobe reported #{frame_count} frames.

      Nothing has been written.
    ERROR
  end


  # ------------------------------------------------------------------------
  # Build an ffconcat file.
  #
  # Each image gets the duration corresponding to its chapter.
  # ------------------------------------------------------------------------

  concat_file = File.join(tmp, "backdrops.ffconcat")

  File.open(concat_file, "w") do |f|
    f.puts "ffconcat version 1.0"

    frames.each_with_index do |frame, i|
      path = frame.gsub("'", "'\\''")

      f.puts "file '#{path}'"
      f.puts format("duration %.6f", durations[i])
    end

    # The concat demuxer needs the final file repeated so that the final
    # duration is respected.
    path = frames.last.gsub("'", "'\\''")
    f.puts "file '#{path}'"
  end


  # ------------------------------------------------------------------------
  # Output filename
  # ------------------------------------------------------------------------

  extension = File.extname(input)
  basename  = File.basename(input, extension)
  directory = File.dirname(input)

  output = File.join(
    directory,
    "#{basename}-fixed#{extension}"
  )

  if File.exist?(output)
    abort "Output already exists: #{output}"
  end


  # ------------------------------------------------------------------------
  # Create the new video.
  #
  # CRF 0 = mathematically lossless H.264.
  #
  # Audio is copied directly from the source.
  # Chapters are copied directly from the source.
  # ------------------------------------------------------------------------

  puts
  puts "Creating corrected video..."

  run!(
    FFMPEG,
    "-hide_banner",

    # Generated backdrop video.
    "-f", "concat",
    "-safe", "0",
    "-i", concat_file,

    # Original source.
    "-i", input,

    # Generated video.
    "-map", "0:v:0",

    # All original audio streams.
    "-map", "1:a?",

    # Preserve subtitles if present.
    "-map", "1:s?",

    # Lossless H.264.
    "-c:v", "libx264",
    "-crf", "0",
    "-preset", "medium",

    # Bit-for-bit audio copy.
    "-c:a", "copy",

    # Bit-for-bit subtitle copy.
    "-c:s", "copy",

    # Preserve chapter metadata.
    "-map_metadata", "1",

    # Use variable frame rate; chapter durations need not align to a
    # constant frame rate.
    "-fps_mode", "vfr",

    "-f", "matroska",

    output
  )

  puts
  puts "Finished."
  puts
  puts "Output:"
  puts output
end
