# frozen_string_literal: true

require "json"
require "open3"
require "pty"
require "time"

# Shared whisper-cli runner. Callers own policy (vocab prompts, windows, metrics).
module WhisperCli
  module_function

  Result = Struct.new(:text, :segments, :json_path, :elapsed_s, keyword_init: true)

  class Error < StandardError; end

  def transcribe(audio_path, language:, model: nil, prompt: nil, out_prefix:, progress: false, cli_args: nil)
    audio_path = File.expand_path(audio_path.to_s)
    raise Error, "audio not found: #{audio_path}" unless File.file?(audio_path)

    model = resolve_model(model)
    bin = resolve_bin
    prefix = out_prefix.to_s
    raise Error, "out_prefix required" if prefix.empty?

    cmd = [bin, "-m", model, "-f", audio_path, "-l", language.to_s, "-oj", "-ojf", "-of", prefix]
    cmd.concat(Array(cli_args)) if cli_args
    # -pp prints "progress = N%" every 5 points. Without it, stderr has no percentage.
    cmd << "-pp" if progress
    prompt = prompt.to_s.strip
    unless prompt.empty?
      cmd += ["--prompt", prompt, "--carry-initial-prompt"]
    end

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _stdout, stderr, status = if progress
                               stream_cmd(cmd)
                             else
                               out, err, st = Open3.capture3(*cmd)
                               [out, err, st]
                             end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    unless status.success?
      tail = stderr.to_s.lines.last(12).join
      raise Error, "whisper-cli failed#{"\n" + tail unless tail.strip.empty?}"
    end

    json_path = "#{prefix}.json"
    raise Error, "expected #{json_path}" unless File.file?(json_path)

    parsed = parse_json(json_path)
    Result.new(
      text: parsed[:text],
      segments: parsed[:segments],
      json_path: json_path,
      elapsed_s: elapsed
    )
  end

  PROGRESS_RE = /progress\s*=\s*(\d+)\s*%/
  BAR_WIDTH = 24

  # whisper-cli fprintf's progress to stderr and does not flush. On a pipe, glibc
  # fully buffers stderr, and a whole book's progress lines never fill that
  # buffer, so the bar stays at 0% until exit. A pty makes stderr a terminal,
  # which glibc leaves unbuffered.
  # Returns [stdout, stderr_tail, status] to match Open3.capture3.
  def stream_cmd(cmd)
    state = {
      pct: nil,
      t0: Process.clock_gettime(Process::CLOCK_MONOTONIC),
      done: false,
      lock: Mutex.new
    }
    render_progress(state, 0)
    master = nil
    slave = nil
    tick = Thread.new do
      until state[:done]
        sleep 1
        break if state[:done]

        paint(state) if $stderr.tty?
      end
    end
    master, slave = PTY.open
    Open3.popen2(*cmd, err: slave) do |stdin, stdout, wait_thr|
      slave.close
      stdin.close
      chunks = []
      size = 0
      buf = String.new(encoding: Encoding::ASCII_8BIT)
      out_thread = Thread.new { stdout.read }
      err_thread = Thread.new do
        # read(4096) waits for a full buffer. A pty signals close with EIO and
        # drops the short read, so progress lines never surface. readpartial
        # returns the bytes already written.
        loop do
          chunk = master.readpartial(4096)
          chunk.force_encoding(Encoding::ASCII_8BIT)
          chunks << chunk
          size += chunk.bytesize
          while size > 8000 && chunks.size > 1
            size -= chunks.shift.bytesize
          end
          buf << chunk
          while (idx = buf.index(/[\r\n]/))
            apply_progress_line(buf.slice!(0, idx + 1), state)
          end
        end
      rescue EOFError, Errno::EIO
        apply_progress_line(buf, state) unless buf.empty?
      end
      out_thread.join
      err_thread.join
      [nil, chunks.join, wait_thr.value]
    end
  ensure
    state[:done] = true if state
    slave.close if slave && !slave.closed?
    master.close if master && !master.closed?
    tick&.join(2)
    finish_progress(state) if state
  end

  def apply_progress_line(line, state)
    return unless (match = line.match(PROGRESS_RE))

    render_progress(state, match[1].to_i)
  end

  def render_progress(state, pct, io: $stderr)
    pct = pct.to_i.clamp(0, 100)
    changed = state[:pct] != pct
    state[:pct] = pct
    return if !changed && !io.tty?

    paint(state, io, line: !io.tty?)
  end

  def paint(state, io = $stderr, line: false)
    pct = state[:pct].to_i
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - state[:t0].to_f
    clock = format_elapsed(elapsed)
    state[:lock].synchronize do
      if line || !io.tty?
        io.puts format("transcribing %3d%%  %s", pct, clock)
      else
        filled = (BAR_WIDTH * pct / 100.0).round
        bar = "#" * filled + "-" * (BAR_WIDTH - filled)
        io.print format("\rtranscribing [%s] %3d%%  %s", bar, pct, clock)
      end
      io.flush
    end
  end

  def format_elapsed(seconds)
    seconds = 0 if seconds.negative?
    total = seconds.to_i
    format("%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
  end

  def finish_progress(state)
    return unless state[:pct] && $stderr.tty?

    state[:lock].synchronize { $stderr.puts }
  end

  def parse_json(path)
    data = JSON.parse(File.read(path))
    raw = data["transcription"] || data["segments"] || []
    segments = raw.is_a?(Array) ? raw : []
    text =
      if data["text"] && !data["text"].to_s.strip.empty?
        data["text"].to_s
      else
        segments.map { |s| s["text"] || s["word"] }.compact.join(" ")
      end
    { text: text.gsub(/\s+/, " ").strip, segments: segments }
  rescue JSON::ParserError => e
    raise Error, "whisper json: #{e.message}"
  end

  def resolve_model(model)
    model = model.to_s.strip
    model = ENV["SUBPIPE_WHISPER_MODEL"].to_s.strip if model.empty?
    if model.empty?
      raise Error, "no whisper model; set SUBPIPE_WHISPER_MODEL or pass --model"
    end
    raise Error, "model not found: #{model}" unless File.file?(model)

    model
  end

  def resolve_bin
    bin = ENV.fetch("SUBPIPE_WHISPER_BIN", "whisper-cli")
    return bin if File.executable?(bin) || system("command", "-v", bin, out: File::NULL, err: File::NULL)

    raise Error, "whisper-cli not on PATH (set SUBPIPE_WHISPER_BIN)"
  end
end
