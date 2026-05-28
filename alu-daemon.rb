#!/usr/bin/env ruby
# alu-daemon.rb — 阿露 RPC 守护进程
# 管理 pi --mode rpc 子进程，通过 Redis pub/sub 对外暴露
# systemd 管理生命周期，Rails 通过 Redis 接入

require 'open3'
require 'redis'
require 'json'
require 'securerandom'

# ── 配置 ──────────────────────────────────────────
ROLEPLAY_DIR = File.expand_path(__dir__)
REDIS_URL    = ENV.fetch('ALU_REDIS_URL', 'redis://localhost:6379/5')
BROADCAST_REDIS_URL = ENV.fetch('ALU_BROADCAST_REDIS_URL', 'redis://localhost:6379/4')
CMD_CHANNEL         = 'alu:rpc:cmd'
EVENT_CHANNEL       = 'alu:rpc:event'
UI_REQUEST_CHANNEL  = 'alu:rpc:ui_request'
UI_RESPONSE_CHANNEL = 'alu:rpc:ui_response'

# ── 全局状态 ──────────────────────────────────────
$redis           = Redis.new(url: REDIS_URL)
$redis_broadcast = Redis.new(url: BROADCAST_REDIS_URL) # ActionCable 用的 DB4
$mutex = Mutex.new
$cmd_queue = Queue.new
$busy      = false # pi 是否正在处理
$pi_stdin  = nil
$pi_stdout = nil
$pi_stderr = nil
$pi_wait   = nil

# ── 日志 ──────────────────────────────────────────
def log(msg)
  $redis.publish(EVENT_CHANNEL, { type: 'daemon', ts: Time.now.to_i, msg: msg }.to_json)
rescue StandardError
  # Redis 挂了也别崩
end

# ── 启动 pi 子进程 ────────────────────────────────
def spawn_pi
  $pi_stdin, $pi_stdout, $pi_stderr, $pi_wait = Open3.popen3(
    'pi', '--mode', 'rpc',
    chdir: ROLEPLAY_DIR
  )
  log("pi spawned, pid=#{$pi_wait.pid}")
end

# ── stderr 转发 ────────────────────────────────────
def stderr_reader
  while (line = $pi_stderr.gets)
    $redis.publish(EVENT_CHANNEL, { type: 'stderr', text: line.strip }.to_json)
  end
rescue IOError, Errno::EPIPE
  # pi 挂了
end

# ── stdout 读取 & 事件转发 ─────────────────────────
def stdout_reader
  while (line = $pi_stdout.gets)
    line = line.strip
    next if line.empty?

    begin
      event = JSON.parse(line)
    rescue JSON::ParserError
      next
    end

    # extension_ui_request → 切 UI 协议处理（异步，不阻塞 stdout 读取）
    if event['type'] == 'extension_ui_request'
      Thread.new { handle_ui_request(event) }
      next
    end

    # agent_end → 标记空闲
    $mutex.synchronize { $busy = false } if event['type'] == 'agent_end'

    # 原样发布到 Redis（DB5: Rails 内部用）
    $redis.publish(EVENT_CHANNEL, line)
    # 同步推到 ActionCable（DB4: 前端 WebSocket）
    begin
      $redis_broadcast.publish('alu', line)
    rescue StandardError
      nil
    end
  end
rescue IOError, Errno::EPIPE
  # pi 退出了
end

# ── Extension UI 协议处理 ─────────────────────────
def handle_ui_request(req)
  json = JSON.generate(req)
  # 广播给前端（ActionCable WebSocket）
  begin
    $redis_broadcast.publish('alu', json)
  rescue StandardError
    nil
  end
  # 同时发内部频道（历史兼容）
  $redis.publish(UI_REQUEST_CHANNEL, json)

  # 不需要回复的类型（fire-and-forget）
  case req['method']
  when 'notify', 'setStatus', 'setWidget', 'setTitle', 'set_editor_text'
    return
  end

  # 需要回复的 dialog 类型：select / confirm / input / editor
  timeout_ms = req['timeout'] || 30_000
  ui_redis = Redis.new(url: REDIS_URL)
  reply = nil

  begin
    Timeout.timeout(timeout_ms / 1000.0 + 2) do
      ui_redis.subscribe(UI_RESPONSE_CHANNEL) do |on|
        on.message do |_ch, msg|
          resp = begin
                   JSON.parse(msg)
          rescue StandardError
                   {}
          end
          if resp['id'] == req['id']
            reply = msg
            ui_redis.unsubscribe
          end
        end
      end
    end
  rescue Timeout::Error
    # pi 那边也会超时，返回默认值
  ensure
    begin
      ui_redis.close
    rescue StandardError
      nil
    end
  end

  return unless reply

    $mutex.synchronize do
      $pi_stdin.puts reply
      $pi_stdin.flush
    end

  # reply 为 nil → 超时，pi 自己会给默认值，不用管
end

# ── Redis 命令订阅 ────────────────────────────────
def redis_subscriber
  $redis.subscribe(CMD_CHANNEL) do |on|
    on.message do |_channel, msg|
      begin
        cmd = JSON.parse(msg)
      rescue JSON::ParserError
        log("invalid JSON: #{msg[0..80]}")
        next
      end
      $cmd_queue << cmd
    end
  end
rescue Redis::BaseConnectionError => e
  log("redis disconnected: #{e.message}")
  sleep 3
  retry
end

# ── 命令处理（主循环）─────────────────────────────
def process_commands
  loop do
    cmd = $cmd_queue.pop # 阻塞等待

    case cmd['type']
    when 'ping'
      $redis.publish(EVENT_CHANNEL, { type: 'pong' }.to_json)

    when 'abort'
      if $busy
        write_to_pi({ type: 'abort' })
        log('aborted')
      end

    when 'list_sessions'
      sessions = list_pi_sessions
      $redis.publish(EVENT_CHANNEL, {
        type: 'response',
        command: 'list_sessions',
        id: cmd['id'],
        success: true,
        data: { sessions: sessions }
      }.to_json)

    when 'list_projects'
      projects = list_projects
      $redis.publish(EVENT_CHANNEL, {
        type: 'response',
        command: 'list_projects',
        id: cmd['id'],
        success: true,
        data: { projects: projects }
      }.to_json)

    else
      # prompt / new_session / switch_session / bash / get_state ...
      # 全部透传给 pi。如果 pi 忙则自动追加 streamingBehavior
      $mutex.synchronize do
        cmd['streamingBehavior'] ||= 'steer' if $busy && cmd['type'] == 'prompt'
        $busy = true
        write_to_pi(cmd)
      end
    end
  end
end

# ── 写入 pi stdin ─────────────────────────────────
# 注意：调用方需要持有 $mutex（process_commands 已持，handle_ui_request 也持）
def write_to_pi(hash)
  $pi_stdin.puts JSON.generate(hash)
  $pi_stdin.flush
rescue Errno::EPIPE => e
  log("write failed (pi pipe broken): #{e.message}")
end

# ── Session 列表（daemon 本地扫，不走 pi）──────────
def list_pi_sessions
  session_dir = File.expand_path('~/.pi/agent/sessions')
  return [] unless Dir.exist?(session_dir)

  Dir.glob(File.join(session_dir, '**/*.jsonl'))
     .sort_by { |f| -File.mtime(f).to_i }
     .first(30)
     .map do |path|
       project = extract_project(path, session_dir)
       info = parse_session_info(path)
       {
         path: path,
         name: File.basename(path, '.jsonl'),
         project: project,
         session_name: info[:session_name],
         first_message: info[:first_message],
         parent_session: info[:parent_session],
         mtime: File.mtime(path).strftime('%Y-%m-%dT%H:%M:%S%:z'),
         size: File.size(path)
       }
     end
rescue StandardError => e
  log("list_pi_sessions error: #{e.message}")
  []
end

# ── Project 列表（扫描所有子目录，不受 30 条限制）─────
def list_projects
  session_dir = File.expand_path('~/.pi/agent/sessions')
  return [] unless Dir.exist?(session_dir)

  Dir.glob(File.join(session_dir, '*'))
     .select { |d| File.directory?(d) }
     .filter_map do |project_dir|
       latest = Dir.glob(File.join(project_dir, '*.jsonl'))
                    .max_by { |f| File.mtime(f).to_i }
       next unless latest

       info = parse_session_info(latest)
       cwd = info[:cwd]
       # 从 cwd 取最后 2 段作为显示名（如 pi-workshop/roleplay）
       display = cwd ? cwd.split('/').last(2).join('/') : extract_project(project_dir, session_dir)

       {
         project: display,
         cwd: cwd,
         path: latest,
         session_name: info[:session_name],
         mtime: File.mtime(latest).strftime('%Y-%m-%dT%H:%M:%S%:z')
       }
     end
     .sort_by { |p| p[:project] || '' }
rescue StandardError => e
  log("list_projects error: #{e.message}")
  []
end

# 从路径解析项目名：--home-luziyi-workshop-pi-workshop-roleplay-- → pi-workshop-roleplay
def extract_project(path, session_dir)
  rel = path.sub(session_dir, '').split('/').reject(&:empty?)
  dir = rel.length >= 2 ? rel[-2] : (rel.first || '')
  cleaned = dir.sub(/^--/, '').sub(/--$/, '')
  # 去掉公共前缀 /home/luziyi/workshop/
  name = cleaned.sub(/^home-luziyi-workshop-/, '') if cleaned.start_with?('home-luziyi-workshop-')
  name || cleaned
rescue StandardError
  nil
end

# 解析 session JSONL，提取名称、首条消息、父 session、工作目录
def parse_session_info(path)
  result = { session_name: nil, first_message: nil, parent_session: nil, cwd: nil }
  File.open(path) do |f|
    f.each_line do |line|
      entry = begin
                JSON.parse(line)
      rescue StandardError
                next
      end

      case entry['type']
      when 'session'
        result[:parent_session] = entry['parentSession'] if entry['parentSession']
        result[:cwd] = entry['cwd'] if entry['cwd']
      when 'session_info'
        result[:session_name] = entry['name']&.strip if entry['name']
      when 'message'
        next if result[:first_message]

        msg = entry['message']
        next unless msg.is_a?(Hash) && msg['role'] == 'user'

        content = msg['content']
        text = if content.is_a?(String)
                 content
               elsif content.is_a?(Array)
                 content.select { |c| c.is_a?(Hash) && c['type'] == 'text' }
                        .map { |c| c['text'] }.join
               end
        result[:first_message] = text&.strip&.[](0, 50) if text
      end

      # 四个字段都拿到了就停
      break if result[:session_name] && result[:first_message] && result[:parent_session] && result[:cwd]
    end
  end
  result
rescue StandardError
  { session_name: nil, first_message: nil, parent_session: nil, cwd: nil }
end

# ── 信号处理 ──────────────────────────────────────
trap('TERM') do
  log('SIGTERM received, shutting down...')
  $pi_stdin&.puts JSON.generate({ type: 'abort' })
  begin
    $pi_stdin&.close
  rescue StandardError
    nil
  end
  exit 0
end
trap('INT') { Process.kill('TERM', Process.pid) }

# ── pi 保活 ────────────────────────────────────────
def run_with_keepalive
  loop do
    spawn_pi

    stdout_thread = Thread.new { stdout_reader }
    stderr_thread = Thread.new { stderr_reader }

    # 等 pi 退出
    $pi_wait.join
    log("pi exited, status=#{$pi_wait.value}")

    [stdout_thread, stderr_thread].each do |t|
                                                t.kill
    rescue StandardError
                                                nil
    end
    $mutex.synchronize { $busy = false }

    log('respawning pi in 3s...')
    sleep 3
  end
end

# ── 入口 ──────────────────────────────────────────
log('alu-daemon starting...')

# 命令处理 & Redis 订阅（独立于 pi 生命周期）
Thread.new { redis_subscriber }
Thread.new { process_commands }

run_with_keepalive
