# frozen_string_literal: true

def safe_send_message(bot, chat_id, text)
  bot.api.send_message(chat_id: chat_id, text: text)
rescue => e
  puts "Ошибка отправки сообщения в Telegram: #{e.class}: #{e.message}"
end

def directory_size_bytes(path)
  return 0 unless path && Dir.exist?(path)

  Dir.glob(File.join(path, "**", "*")).sum do |entry|
    File.file?(entry) ? File.size(entry) : 0
  rescue
    0
  end
end

def terminate_process_group(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
rescue Errno::EPERM, NotImplementedError
  begin
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end
end

def run_command_with_limits(*cmd, timeout_seconds:, watched_dir: nil, max_dir_bytes: nil)
  stdout_data = +""
  stderr_data = +""
  status = nil
  timed_out = false
  limit_exceeded = false

  Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
    stdin.close
    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }
    deadline = Time.now + timeout_seconds

    loop do
      break if wait_thr.join(0.25)

      if Time.now >= deadline
        timed_out = true
        terminate_process_group(wait_thr.pid, "TERM")
        break
      end

      if max_dir_bytes && watched_dir && directory_size_bytes(watched_dir) > max_dir_bytes
        limit_exceeded = true
        terminate_process_group(wait_thr.pid, "TERM")
        break
      end
    end

    unless wait_thr.join(5)
      terminate_process_group(wait_thr.pid, "KILL")
      wait_thr.join
    end

    stdout_data = stdout_reader.value
    stderr_data = stderr_reader.value
    status = wait_thr.value
  end

  CommandResult.new(
    stdout: stdout_data,
    stderr: stderr_data,
    status: status,
    timed_out: timed_out,
    limit_exceeded: limit_exceeded
  )
end

def command_error_output(result)
  error_output = result.stderr.to_s.strip
  error_output.empty? ? result.stdout.to_s.strip : error_output
end

def env_value(name)
  value = ENV[name].to_s.strip
  value.empty? ? nil : value
end
