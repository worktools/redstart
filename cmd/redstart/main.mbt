///|
/// Entry point for the redstart process manager CLI.
fn main {
  let all_args = @sys.get_cli_args()
  let argv : Array[String] = []
  for i in 1..<all_args.length() {
    argv.push(all_args[i])
  }
  let cmd = build_cli()
  let matches = cmd.parse(argv~, env={}) catch {
    err => {
      println(err.to_string())
      @sys.exit(1)
      panic()
    }
  }
  match matches.subcommand {
    None => {
      println(cmd.render_help())
      @sys.exit(0)
    }
    Some(("init", _)) => run_init()
    Some(("add", m)) => run_add(m)
    Some(("remove", m)) => run_remove(m)
    Some(("start", m)) => run_start(m)
    Some(("stop", m)) => run_stop(m)
    Some(("restart", m)) => run_restart(m)
    Some(("list", m)) => run_list(m)
    Some(("status", m)) => run_status(m)
    Some(("logs", m)) => run_logs(m)
    Some(("doc", m)) => run_doc(m)
    Some(("inspect", m)) => run_inspect(m)
    Some(("wait", m)) => run_wait(m)
    Some((sub, _)) => {
      println("unknown subcommand: " + sub)
      @sys.exit(1)
    }
  }
}

///|
fn build_cli() -> @argparse.Command {
  @argparse.Command(
    "redstart",
    about="Lightweight process manager for local development",
    subcommand_required=true,
    subcommands=[
      @argparse.Command(
        "init",
        about="Initialize redstart.json5 in current directory",
      ),
      @argparse.Command(
        "add",
        about="Add a process definition",
        options=[
          @argparse.OptionArg("cwd", about="Working directory for the process"),
          @argparse.OptionArg(
            "env",
            short='e',
            about="Environment variables as comma-separated KEY=VAL pairs",
          ),
        ],
        positionals=[
          @argparse.PositionArg(
            "proc_alias",
            about="Unique alias name for the process",
          ),
          @argparse.PositionArg(
            "command",
            about="Shell command to run",
            num_args=@argparse.ValueRange(lower=1),
          ),
        ],
      ),
      @argparse.Command(
        "remove",
        about="Remove a process definition (must be stopped first)",
        positionals=[
          @argparse.PositionArg("target", about="Process alias or id"),
        ],
      ),
      @argparse.Command(
        "start",
        about="Start a process (or all stopped processes)",
        positionals=[
          @argparse.PositionArg(
            "target",
            about="Process alias or id (omit to start all)",
            num_args=@argparse.ValueRange(lower=0, upper=1),
          ),
        ],
      ),
      @argparse.Command(
        "stop",
        about="Stop a process (or all running processes)",
        positionals=[
          @argparse.PositionArg(
            "target",
            about="Process alias or id (omit to stop all)",
            num_args=@argparse.ValueRange(lower=0, upper=1),
          ),
        ],
      ),
      @argparse.Command("restart", about="Restart a process", positionals=[
        @argparse.PositionArg("target", about="Process alias or id"),
      ]),
      @argparse.Command("list", about="List all processes and their status", flags=[
        @argparse.FlagArg("json", about="Output as JSON array"),
      ]),
      @argparse.Command(
        "status",
        about="Show process status (all or specific)",
        flags=[@argparse.FlagArg("json", about="Output as JSON")],
        positionals=[
          @argparse.PositionArg(
            "target",
            about="Process alias or id (omit to show all)",
            num_args=@argparse.ValueRange(lower=0, upper=1),
          ),
        ],
      ),
      @argparse.Command(
        "logs",
        about="Show recent log output for a process",
        options=[
          @argparse.OptionArg(
            "lines",
            short='n',
            about="Number of lines to show",
            default_values=["50"],
          ),
        ],
        flags=[
          @argparse.FlagArg("stdout", about="Show only stdout"),
          @argparse.FlagArg("stderr", about="Show only stderr"),
        ],
        positionals=[
          @argparse.PositionArg("target", about="Process alias or id"),
        ],
      ),
      @argparse.Command(
        "doc",
        about="Show documentation overview or per-command reference",
        positionals=[
          @argparse.PositionArg(
            "topic",
            about="Command name to look up (omit for overview)",
            num_args=@argparse.ValueRange(lower=0, upper=1),
          ),
        ],
      ),
      @argparse.Command(
        "inspect",
        about="Dump full process state as JSON (machine-readable)",
        positionals=[
          @argparse.PositionArg("target", about="Process alias or id"),
        ],
      ),
      @argparse.Command(
        "wait",
        about="Block until a process is running (useful in scripts/agents)",
        options=[
          @argparse.OptionArg(
            "timeout",
            short='t',
            about="Max seconds to wait (default: 30)",
            default_values=["30"],
          ),
        ],
        positionals=[
          @argparse.PositionArg("target", about="Process alias or id"),
        ],
      ),
    ],
  )
}

///|
fn run_init() -> Unit {
  if @redstart.config_file_exists() {
    println("redstart.json5 already exists")
    return
  }
  let config = @redstart.new_config()
  @redstart.save_config(config) catch {
    e => {
      println("error: " + e.to_string())
      @sys.exit(1)
    }
  }
  println("Initialized redstart.json5")
}

///|
fn run_add(m : @argparse.Matches) -> Unit {
  let proc_alias = get_first_value(m, "proc_alias")
  let cmd_parts = m.values.get("command").unwrap_or([])
  if cmd_parts.is_empty() {
    println("error: command is required")
    @sys.exit(1)
  }
  let command = cmd_parts.join(" ")
  let cwd = match m.values.get("cwd") {
    None => None
    Some(arr) => arr.get(0)
  }
  // Parse --env KEY1=VAL1,KEY2=VAL2 (comma-separated)
  let env : Map[String, String] = {}
  for raw in m.values.get("env").unwrap_or([]) {
    for kv in raw.split(",") {
      let kv = kv.to_owned()
      let mut eq_pos = -1
      for i in 0..<kv.length() {
        if kv.unsafe_get(i).to_int() == 61 {
          eq_pos = i
          break
        }
      }
      if eq_pos == -1 {
        println("warning: ignoring malformed env var (no '='): " + kv)
      } else {
        let k = kv[0:eq_pos].to_owned()
        let v = kv[eq_pos + 1:kv.length()].to_owned()
        env[k] = v
      }
    }
  }
  let config = load_config_or_exit()
  if @redstart.find_process(config, proc_alias) is Some(_) {
    println("error: alias already exists: " + proc_alias)
    @sys.exit(1)
  }
  let entry = @redstart.new_process_entry(
    @redstart.generate_id(@redstart.now(), proc_alias),
    proc_alias,
    command,
    cwd,
    env,
    @redstart.now().to_string(),
  )
  config.add_process(entry)
  @redstart.save_config(config) catch {
    e => {
      println("error: " + e.to_string())
      @sys.exit(1)
    }
  }
  println("Added process '" + proc_alias + "' (id: " + entry.id + ")")
  println("  command: " + command)
  match cwd {
    None => ()
    Some(d) => println("  cwd: " + d)
  }
  if !env.is_empty() {
    for k, v in env {
      println("  env: " + k + "=" + v)
    }
  }
}

///|
fn run_remove(m : @argparse.Matches) -> Unit {
  let target = get_first_value(m, "target")
  let config = load_config_or_exit()
  let entry = match @redstart.find_process(config, target) {
    None => {
      println("error: process not found: " + target)
      @sys.exit(1)
      panic()
    }
    Some(e) => e
  }
  if entry.status == "running" {
    println("error: process is running, stop it first: " + entry.proc_name)
    @sys.exit(1)
  }
  ignore(config.remove_process(target))
  @redstart.save_config(config) catch {
    e => {
      println("error: " + e.to_string())
      @sys.exit(1)
    }
  }
  println("Removed process: " + target)
}

///|
fn run_start(m : @argparse.Matches) -> Unit {
  let target_arr = m.values.get("target").unwrap_or([])
  let target = if target_arr.is_empty() { None } else { Some(target_arr[0]) }
  let config = load_config_or_exit()
  match target {
    None => {
      let mut count = 0
      for p in config.processes {
        if p.status != "running" {
          start_one(config, p.proc_name)
          count = count + 1
        }
      }
      if count == 0 {
        println("No stopped processes to start")
      }
    }
    Some(t) => start_one(config, t)
  }
}

///|
fn start_one(config : @redstart.Config, target : String) -> Unit {
  let entry = match @redstart.find_process(config, target) {
    None => {
      println("error: process not found: " + target)
      @sys.exit(1)
      panic()
    }
    Some(e) => e
  }
  let alive = match entry.pid {
    None => false
    Some(pid) => @redstart.is_process_alive(pid)
  }
  if alive {
    println(
      "error: process already running: " +
      entry.proc_name +
      " (pid: " +
      @redstart.format_pid(entry.pid) +
      ")",
    )
    @sys.exit(1)
  }
  println(
    "Starting '" +
    entry.proc_name +
    "' as a new process group (child processes, if any, will be managed together)...",
  )
  try {
    let (pid, started_at) = @redstart.start_with_retry(entry, 3)
    entry.mark_running(pid, started_at)
    let pid_path = @redstart.pid_file_path(entry.proc_name)
    ignore(
      @fs.write_string_to_file(pid_path, pid.to_string()) catch {
        _ => ()
      },
    )
    @redstart.save_config(config) catch {
      e => println("warning: failed to save config: " + e.to_string())
    }
    println(" started (process group leader pid: " + pid.to_string() + ")")
    println(
      " note: child processes spawned by this command will be stopped and restarted together with '" +
      entry.proc_name +
      "'",
    )
  } catch {
    e => {
      println(" failed")
      println("error: " + e.to_string())
      entry.mark_failed()
      ignore(@redstart.save_config(config) catch { _ => () })
      @sys.exit(1)
    }
  }
}

///|
fn run_stop(m : @argparse.Matches) -> Unit {
  let target_arr = m.values.get("target").unwrap_or([])
  let target = if target_arr.is_empty() { None } else { Some(target_arr[0]) }
  let config = load_config_or_exit()
  match target {
    None => {
      let mut count = 0
      for p in config.processes {
        if p.status == "running" {
          stop_one(config, p.proc_name)
          count = count + 1
        }
      }
      if count == 0 {
        println("No running processes to stop")
      }
    }
    Some(t) => stop_one(config, t)
  }
}

///|
fn stop_one(config : @redstart.Config, target : String) -> Unit {
  let entry = match @redstart.find_process(config, target) {
    None => {
      println("error: process not found: " + target)
      @sys.exit(1)
      panic()
    }
    Some(e) => e
  }
  let pid = match entry.pid {
    None => {
      println("error: process is not running: " + entry.proc_name)
      @sys.exit(1)
      panic()
    }
    Some(p) => p
  }
  if !@redstart.is_process_alive(pid) {
    println("Process not running, updating status: " + entry.proc_name)
    entry.mark_stopped(@redstart.now().to_string(), None)
    ignore(@redstart.save_config(config) catch { _ => () })
    return
  }
  println(
    "Stopping '" +
    entry.proc_name +
    "' (process group leader pid: " +
    pid.to_string() +
    ")...",
  )
  println(
    " this will also stop child processes spawned by '" +
    entry.proc_name +
    "', if any",
  )
  @redstart.stop_gracefully(pid)
  entry.mark_stopped(@redstart.now().to_string(), None)
  let pid_path = @redstart.pid_file_path(entry.proc_name)
  ignore(@fs.remove_file(pid_path) catch { _ => () })
  @redstart.save_config(config) catch {
    e => println("warning: failed to save config: " + e.to_string())
  }
  println(" stopped process group")
}

///|
fn run_restart(m : @argparse.Matches) -> Unit {
  let target = get_first_value(m, "target")
  let config = load_config_or_exit()
  let entry = match @redstart.find_process(config, target) {
    None => {
      println("error: process not found: " + target)
      @sys.exit(1)
      panic()
    }
    Some(e) => e
  }
  println(
    "Restarting '" +
    entry.proc_name +
    "' by replacing its whole process group (including child processes, if any)...",
  )
  if entry.status == "running" {
    stop_one(config, target)
  }
  start_one(config, target)
}

///|
fn run_list(m : @argparse.Matches) -> Unit {
  let config = load_config_or_exit()
  refresh_statuses(config)
  let as_json = m.flags.get("json").unwrap_or(false)
  if as_json {
    println(@redstart.json_to_string(config.processes.to_json()))
    return
  }
  if config.processes.is_empty() {
    println("No processes defined. Use 'redstart add' to add one.")
    return
  }
  // Compute dynamic column widths based on actual content
  let mut alias_w = 5 // "ALIAS"
  let mut id_w = 8 // "ID" (always show 8-char id)
  let mut status_w = 6 // "STATUS"
  let mut pid_w = 3 // "PID"
  for p in config.processes {
    if p.proc_name.length() > alias_w {
      alias_w = p.proc_name.length()
    }
    let pid_str = @redstart.format_pid(p.pid)
    if pid_str.length() > pid_w {
      pid_w = pid_str.length()
    }
    if p.status.length() > status_w {
      status_w = p.status.length()
    }
  }
  // Add padding gap of 2 spaces after each column
  alias_w = alias_w + 2
  id_w = id_w + 2
  status_w = status_w + 2
  pid_w = pid_w + 2
  let sep_w = alias_w + id_w + status_w + pid_w + 20
  println(
    pad("ALIAS", alias_w) +
    pad("ID", id_w) +
    pad("STATUS", status_w) +
    pad("PID", pid_w) +
    "COMMAND",
  )
  println(repeat_str("-", sep_w))
  for p in config.processes {
    let id_short = if p.id.length() >= 8 { p.id[0:8].to_owned() } else { p.id }
    println(
      pad(p.proc_name, alias_w) +
      pad(id_short, id_w) +
      pad(p.status, status_w) +
      pad(@redstart.format_pid(p.pid), pid_w) +
      truncate(p.command, 40),
    )
  }
}

///|
fn run_status(m : @argparse.Matches) -> Unit {
  let target_arr = m.values.get("target").unwrap_or([])
  let target = if target_arr.is_empty() { None } else { Some(target_arr[0]) }
  let as_json = m.flags.get("json").unwrap_or(false)
  let config = load_config_or_exit()
  match target {
    None => run_list(m)
    Some(t) => {
      let entry = match @redstart.find_process(config, t) {
        None => {
          println("error: process not found: " + t)
          @sys.exit(1)
          panic()
        }
        Some(e) => e
      }
      refresh_entry_status(entry)
      ignore(@redstart.save_config(config) catch { _ => () })
      if as_json {
        println(@redstart.json_to_string(entry.to_json()))
        return
      }
      println("Process:  " + entry.proc_name)
      println("  ID:       " + entry.id)
      println("  Command:  " + entry.command)
      match entry.cwd {
        None => ()
        Some(d) => println("  CWD:      " + d)
      }
      println("  Status:   " + entry.status)
      println("  PID:      " + @redstart.format_pid(entry.pid))
      match entry.started_at {
        None => ()
        Some(ts) => println("  Started:  " + ts)
      }
      match entry.stopped_at {
        None => ()
        Some(ts) => println("  Stopped:  " + ts)
      }
      match entry.exit_code {
        None => ()
        Some(c) => println("  Exit:     " + c.to_string())
      }
      println("  Retries:  " + entry.retry_count.to_string())
      println("  Stdout:   " + @redstart.stdout_log_path(entry.proc_name))
      println("  Stderr:   " + @redstart.stderr_log_path(entry.proc_name))
    }
  }
}

///|
fn run_logs(m : @argparse.Matches) -> Unit {
  let target = get_first_value(m, "target")
  let lines_arr = m.values.get("lines").unwrap_or(["50"])
  let lines_str = if lines_arr.is_empty() { "50" } else { lines_arr[0] }
  let n = parse_int_or(lines_str, 50)
  let show_stdout_only = m.flags.get("stdout").unwrap_or(false)
  let show_stderr_only = m.flags.get("stderr").unwrap_or(false)
  let config = load_config_or_exit()
  let entry = match @redstart.find_process(config, target) {
    None => {
      println("error: process not found: " + target)
      @sys.exit(1)
      panic()
    }
    Some(e) => e
  }
  if show_stderr_only {
    print_log_section("stderr", @redstart.stderr_log_path(entry.proc_name), n)
  } else if show_stdout_only {
    print_log_section("stdout", @redstart.stdout_log_path(entry.proc_name), n)
  } else {
    print_log_section("stdout", @redstart.stdout_log_path(entry.proc_name), n)
    println("")
    print_log_section("stderr", @redstart.stderr_log_path(entry.proc_name), n)
  }
}

///|
fn print_log_section(name : String, path : String, n : Int) -> Unit {
  println("=== " + name + " (" + path + ") ===")
  let lines = @redstart.read_last_lines(path, n) catch {
    e => {
      println("error: " + e.to_string())
      []
    }
  }
  if lines.is_empty() {
    println("(no output)")
  } else {
    for line in lines {
      println(line)
    }
  }
}

///|
fn run_doc(m : @argparse.Matches) -> Unit {
  let topic_arr = m.values.get("topic").unwrap_or([])
  let topic = if topic_arr.is_empty() { None } else { Some(topic_arr[0]) }
  match topic {
    None => print_doc_overview()
    Some(t) => print_doc_topic(t)
  }
}

///|
fn print_doc_overview() -> Unit {
  println(
    "redstart — Lightweight process manager for local development and agent automation",
  )
  println("")
  println("QUICK START")
  println("  redstart init              # create redstart.json5")
  println("  redstart add web 'node .' # define a process")
  println("  redstart start web         # start it")
  println("  redstart list              # see all processes")
  println("  redstart logs web          # tail logs")
  println("  redstart stop web          # stop it")
  println("")
  println("COMMANDS")
  println(
    "  init                       Initialize redstart.json5 in current directory",
  )
  println("  add <alias> <command>      Add a process definition")
  println("    --cwd <dir>              Set working directory")
  println("    --env KEY=VAL            Set environment variable (repeatable)")
  println("  remove <alias|id>          Remove a stopped process")
  println("  start [alias|id]           Start a process (or all stopped)")
  println("  stop  [alias|id]           Stop a process (or all running)")
  println("  restart <alias|id>         Stop then start a process")
  println("  list [--json]              List all processes")
  println("  status [alias|id] [--json] Show process status")
  println("  inspect <alias|id>         Dump process state as JSON")
  println("  logs <alias|id> [-n N]     Show last N lines of logs")
  println("    --stdout / --stderr      Show only one stream")
  println(
    "  wait <alias|id> [-t N]     Block until process is running (timeout Ns)",
  )
  println(
    "  doc [command]              Show this overview or per-command reference",
  )
  println("")
  println("DATA FILES")
  println(
    "  redstart.json5             Config and state (committed or gitignored)",
  )
  println("  .redstart-monitor/<alias>/stdout.log")
  println("  .redstart-monitor/<alias>/stderr.log")
  println("  .redstart-monitor/<alias>/pid")
  println("")
  println("AGENT / SCRIPT USAGE")
  println("  # Machine-readable output:")
  println("  redstart list --json")
  println("  redstart status web --json")
  println("  redstart inspect web")
  println("")
  println("  # Wait for a process to become ready before proceeding:")
  println("  redstart start web && redstart wait web --timeout 10")
  println("")
  println("  # Pass environment variables to a process:")
  println("  redstart add api 'python app.py' --env PORT=8000,DEBUG=1")
  println("")
  println("  # Check if a specific process is running (exit code 0 = running):")
  println("  redstart inspect web | grep '\"status\": \"running\"'")
  println("")
  println("EXIT CODES")
  println("  0   Success / process is running")
  println("  1   Error / process not found / timeout")
  println("")
  println("Run 'redstart doc <command>' for detailed per-command reference.")
}

///|
fn print_doc_topic(topic : String) -> Unit {
  match topic {
    "init" => {
      println(
        "init — Initialize a new redstart.json5 in the current directory.",
      )
      println("")
      println("USAGE")
      println("  redstart init")
      println("")
      println("NOTES")
      println("  Creates redstart.json5 with an empty process list.")
      println(
        "  Safe to run in any directory; exits with a message if the file already exists.",
      )
    }
    "add" => {
      println("add — Define a new managed process.")
      println("")
      println("USAGE")
      println(
        "  redstart add <alias> <command...> [--cwd <dir>] [--env KEY=VAL]...",
      )
      println("")
      println("ARGS")
      println(
        "  <alias>      Unique name used to reference the process in other commands.",
      )
      println(
        "  <command>    Shell command to run. Multi-word commands are joined with spaces.",
      )
      println("")
      println("OPTIONS")
      println(
        "  --cwd <dir>      Working directory. Defaults to the current directory.",
      )
      println(
        "  --env KEY=VAL,...    Set environment variables (comma-separated).",
      )
      println("")
      println("EXAMPLES")
      println("  redstart add web 'node server.js'")
      println(
        "  redstart add api python app.py --cwd ./backend --env PORT=8080,DEBUG=1",
      )
    }
    "remove" => {
      println("remove — Remove a process definition from redstart.json5.")
      println("")
      println("USAGE")
      println("  redstart remove <alias|id>")
      println("")
      println("NOTES")
      println(
        "  The process must be stopped first. Use 'redstart stop <alias>' if needed.",
      )
    }
    "start" => {
      println("start — Start a process (with up to 3 automatic retries).")
      println("")
      println("USAGE")
      println("  redstart start [<alias|id>]")
      println("")
      println("NOTES")
      println("  With no argument, starts all processes not currently running.")
      println(
        "  On success the PID is recorded in .redstart-monitor/<alias>/pid.",
      )
      println(
        "  Stdout/stderr are redirected to .redstart-monitor/<alias>/stdout.log and stderr.log.",
      )
      println(
        "  The process is detached (double-fork) so it survives terminal closure.",
      )
    }
    "stop" => {
      println("stop — Stop a running process gracefully.")
      println("")
      println("USAGE")
      println("  redstart stop [<alias|id>]")
      println("")
      println("NOTES")
      println("  With no argument, stops all running processes.")
      println("  Sends SIGTERM and waits up to 5 seconds, then sends SIGKILL.")
    }
    "restart" => {
      println("restart — Stop then start a process.")
      println("")
      println("USAGE")
      println("  redstart restart <alias|id>")
    }
    "list" => {
      println("list — List all defined processes and their current status.")
      println("")
      println("USAGE")
      println("  redstart list [--json]")
      println("")
      println("OPTIONS")
      println(
        "  --json    Output a JSON array of process objects instead of a table.",
      )
      println("")
      println("STATUS VALUES")
      println("  running   Process is alive (PID confirmed).")
      println("  stopped   Process exited or was never started.")
      println("  failed    Process failed to start after all retries.")
      println("  unknown   Process was running but PID record was lost.")
    }
    "status" => {
      println("status — Show detailed status for one process, or list all.")
      println("")
      println("USAGE")
      println("  redstart status [<alias|id>] [--json]")
      println("")
      println("OPTIONS")
      println("  --json    Output JSON instead of human-readable text.")
    }
    "inspect" => {
      println("inspect — Dump the full state of one process as JSON.")
      println("")
      println("USAGE")
      println("  redstart inspect <alias|id>")
      println("")
      println("NOTES")
      println(
        "  Equivalent to 'redstart status <alias> --json' but always JSON.",
      )
      println("  Intended for agent/script consumption. Fields:")
      println("    id, proc_name, command, cwd, env, created_at,")
      println("    status, pid, started_at, stopped_at, exit_code, retry_count")
    }
    "logs" => {
      println(
        "logs — Show the last N lines of stdout and/or stderr for a process.",
      )
      println("")
      println("USAGE")
      println("  redstart logs <alias|id> [-n <lines>] [--stdout] [--stderr]")
      println("")
      println("OPTIONS")
      println("  -n <lines>   Number of lines to show (default: 50).")
      println("  --stdout     Show only stdout.")
      println("  --stderr     Show only stderr.")
      println("")
      println("NOTES")
      println(
        "  Log files are at .redstart-monitor/<alias>/stdout.log and stderr.log.",
      )
    }
    "wait" => {
      println("wait — Block until a process reaches 'running' status.")
      println("")
      println("USAGE")
      println("  redstart wait <alias|id> [--timeout <seconds>]")
      println("")
      println("OPTIONS")
      println("  -t, --timeout <seconds>   Maximum time to wait (default: 30).")
      println("")
      println("EXIT CODES")
      println("  0   Process is now running.")
      println("  1   Timeout expired or process does not exist.")
      println("")
      println("NOTES")
      println(
        "  Polls every 500ms. Useful in scripts and agent workflows to ensure",
      )
      println("  a process is ready before sending requests to it.")
      println("")
      println("EXAMPLE")
      println("  redstart start web && redstart wait web --timeout 15")
    }
    "doc" => {
      println("doc — Show documentation.")
      println("")
      println("USAGE")
      println("  redstart doc [<command>]")
      println("")
      println("  With no argument: show full overview.")
      println(
        "  With a command name: show detailed reference for that command.",
      )
    }
    _ => {
      println("No documentation found for: '" + topic + "'")
      println(
        "Available topics: init, add, remove, start, stop, restart, list, status, inspect, logs, wait, doc",
      )
      @sys.exit(1)
    }
  }
}

///|
fn run_inspect(m : @argparse.Matches) -> Unit {
  let target = get_first_value(m, "target")
  let config = load_config_or_exit()
  let entry = match @redstart.find_process(config, target) {
    None => {
      println("error: process not found: " + target)
      @sys.exit(1)
      panic()
    }
    Some(e) => e
  }
  refresh_entry_status(entry)
  ignore(@redstart.save_config(config) catch { _ => () })
  println(@redstart.json_to_string(entry.to_json()))
}

///|
fn run_wait(m : @argparse.Matches) -> Unit {
  let target = get_first_value(m, "target")
  let timeout_arr = m.values.get("timeout").unwrap_or(["30"])
  let timeout_str = if timeout_arr.is_empty() { "30" } else { timeout_arr[0] }
  let timeout_s = parse_int_or(timeout_str, 30)
  let config = load_config_or_exit()
  match @redstart.find_process(config, target) {
    None => {
      println("error: process not found: " + target)
      @sys.exit(1)
    }
    Some(_) => ()
  }
  let deadline_ms = @redstart.now() + timeout_s.to_int64() * 1000L
  while true {
    // Reload config each iteration so we see updates from other commands
    let cfg = @redstart.load_config() catch {
      e => {
        println("error: " + e.to_string())
        @sys.exit(1)
        panic()
      }
    }
    let entry = match @redstart.find_process(cfg, target) {
      None => {
        println("error: process not found: " + target)
        @sys.exit(1)
        panic()
      }
      Some(e) => e
    }
    if entry.status == "running" {
      match entry.pid {
        Some(pid) if @redstart.is_process_alive(pid) => {
          println("running (pid: " + pid.to_string() + ")")
          return
        }
        _ => ()
      }
    }
    if @redstart.now() >= deadline_ms {
      println("error: timeout waiting for process to start: " + target)
      @sys.exit(1)
    }
    @redstart.sleep_ms(500)
  }
}

///|
fn load_config_or_exit() -> @redstart.Config {
  @redstart.load_config() catch {
    e => {
      println("error: " + e.to_string())
      @sys.exit(1)
      panic()
    }
  }
}

///|
fn get_first_value(m : @argparse.Matches, name : String) -> String {
  match m.values.get(name) {
    None => {
      println("error: required argument missing: " + name)
      @sys.exit(1)
      panic()
    }
    Some(arr) =>
      if arr.is_empty() {
        println("error: required argument missing: " + name)
        @sys.exit(1)
        panic()
      } else {
        arr[0]
      }
  }
}

///|
fn refresh_statuses(config : @redstart.Config) -> Unit {
  for p in config.processes {
    refresh_entry_status(p)
  }
  ignore(@redstart.save_config(config) catch { _ => () })
}

///|
fn refresh_entry_status(entry : @redstart.ProcessEntry) -> Unit {
  match entry.pid {
    None => if entry.status == "running" { entry.mark_unknown() }
    Some(pid) =>
      if entry.status == "running" && !@redstart.is_process_alive(pid) {
        entry.mark_stopped(@redstart.now().to_string(), None)
      }
  }
}

///|
fn pad(s : String, width : Int) -> String {
  if s.length() >= width {
    s[0:width].to_owned()
  } else {
    let buf = StringBuilder::new()
    buf.write_string(s)
    for _ in s.length()..<width {
      buf.write_char(' ')
    }
    buf.to_string()
  }
}

///|
fn truncate(s : String, max_len : Int) -> String {
  if s.length() <= max_len {
    s
  } else {
    s[0:max_len - 3].to_owned() + "..."
  }
}

///|
fn repeat_str(s : String, n : Int) -> String {
  let buf = StringBuilder::new()
  for _ in 0..<n {
    buf.write_string(s)
  }
  buf.to_string()
}

///|
fn parse_int_or(s : String, default : Int) -> Int {
  let mut result = 0
  let mut i = 0
  let len = s.length()
  while i < len {
    let c = s.unsafe_get(i).to_int()
    if c >= 48 && c <= 57 {
      result = result * 10 + c - 48
      i = i + 1
    } else {
      return default
    }
  }
  if result == 0 {
    default
  } else {
    result
  }
}
