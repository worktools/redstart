// Main package file for the redstart process manager library.
// Contains data types, config I/O, and process state management.

///|
/// Error type for all redstart operations.
pub suberror RedstartError {
  RedstartError(String)
}

///|
pub impl Show for RedstartError with output(self, logger) {
  match self {
    RedstartError(msg) => logger.write_string(msg)
  }
}

///|
/// A single managed process entry, combining its definition and runtime state.
/// Note: `proc_name` is used internally (MoonBit reserves `alias`).
pub struct ProcessEntry {
  id : String
  proc_name : String // displayed as "alias" to users
  command : String
  cwd : String?
  env : Map[String, String]
  created_at : String
  mut status : String // "running" | "stopped" | "failed" | "unknown"
  mut pid : Int?
  mut started_at : String?
  mut stopped_at : String?
  mut exit_code : Int?
  mut retry_count : Int
} derive(ToJson, FromJson, Debug)

///|
pub impl Show for ProcessEntry with output(self, logger) {
  let pid_str = match self.pid {
    None => "null"
    Some(n) => n.to_string()
  }
  logger.write_string(
    "ProcessEntry { name: \{self.proc_name}, status: \{self.status}, pid: \{pid_str} }",
  )
}

///|
/// Update entry to reflect a successful start.
pub fn ProcessEntry::mark_running(
  self : ProcessEntry,
  pid : Int,
  ts : String,
) -> Unit {
  self.status = "running"
  self.pid = Some(pid)
  self.started_at = Some(ts)
  self.stopped_at = None
  self.exit_code = None
  self.retry_count = 0
}

///|
/// Update entry to reflect a clean stop.
pub fn ProcessEntry::mark_stopped(
  self : ProcessEntry,
  ts : String,
  code : Int?,
) -> Unit {
  self.status = "stopped"
  self.pid = None
  self.stopped_at = Some(ts)
  self.exit_code = code
}

///|
/// Update entry to reflect a failed start.
pub fn ProcessEntry::mark_failed(self : ProcessEntry) -> Unit {
  self.status = "failed"
  self.pid = None
  self.retry_count = self.retry_count + 1
}

///|
/// Update entry status to unknown (lost track of process).
pub fn ProcessEntry::mark_unknown(self : ProcessEntry) -> Unit {
  self.status = "unknown"
  self.pid = None
}

///|
/// Root configuration / state file structure.
pub struct Config {
  version : String
  mut processes : Array[ProcessEntry]
} derive(ToJson, FromJson, Debug)

///|
pub impl Show for Config with output(self, logger) {
  logger.write_string(
    "Config { version: \{self.version}, processes: \{self.processes.length()} }",
  )
}

///|
/// Add a process entry to the config.
pub fn Config::add_process(self : Config, entry : ProcessEntry) -> Unit {
  self.processes.push(entry)
}

///|
/// Remove a process entry by name or id.
pub fn Config::remove_process(self : Config, target : String) -> Bool {
  let before = self.processes.length()
  self.processes = self.processes.filter(fn(p) {
    p.proc_name != target && p.id != target
  })
  self.processes.length() < before
}

///|
pub let config_file : String = "redstart.json5"

///|
pub let monitor_dir : String = ".redstart-monitor"

///|
/// Load config from redstart.json5 in current directory.
pub fn load_config() -> Config raise RedstartError {
  guard @fs.path_exists(config_file) else {
    raise RedstartError("redstart.json5 not found, run 'redstart init' first")
  }
  let content = @fs.read_file_to_string(config_file) catch {
    e => raise RedstartError("failed to read config: \{@debug.to_repr(e)}")
  }
  let json = @json5.parse_json(content) catch {
    e => raise RedstartError("failed to parse config: \{@debug.to_repr(e)}")
  }
  @json.from_json(json) catch {
    e => raise RedstartError("failed to decode config: \{@debug.to_repr(e)}")
  }
}

///|
/// Save config to redstart.json5 in pretty-printed form.
pub fn save_config(config : Config) -> Unit raise RedstartError {
  let json = config.to_json()
  let content = json_to_pretty_string(json)
  @fs.write_string_to_file(config_file, content) catch {
    e => raise RedstartError("failed to write config: \{@debug.to_repr(e)}")
  }
}

///|
/// Find a process entry by proc_name (alias) or id.
pub fn find_process(config : Config, target : String) -> ProcessEntry? {
  for p in config.processes {
    if p.proc_name == target || p.id == target {
      return Some(p)
    }
  }
  None
}

///|
/// Generate a unique 8-character ID from a timestamp mixed with a seed string.
/// Mixing in the seed ensures IDs differ even when called multiple times per second.
pub fn generate_id(now_ts : Int64, seed : String) -> String {
  // Hash the seed into an Int64 using djb2 style
  let mut h = 5381L
  for c in seed {
    h = h * 33L + c.to_int().to_int64()
  }
  let buf = StringBuilder::new()
  let mut n = now_ts ^ (h * 0x9e3779b97f4a7c15L)
  for _ in 0..<8 {
    let idx = (n % 36L).to_int().abs() % 36
    let char_code = if idx < 26 { 97 + idx } else { 48 + idx - 26 }
    buf.write_char(char_code.unsafe_to_char())
    n = n / 36L + n * 31L
  }
  buf.to_string()
}

///|
/// Serialize Json to compact string (for machine-readable / inspect output).
pub fn json_to_string(json : Json) -> String {
  @json5.stringify_json(json) catch {
    _ => "null"
  }
}

///|
/// Serialize Json to a pretty-printed string with 2-space indentation.
pub fn json_to_pretty_string(json : Json) -> String {
  let buf = StringBuilder::new()
  json_write_pretty(buf, json, 0)
  buf.write_char('\n')
  buf.to_string()
}

///|
fn json_write_pretty(buf : StringBuilder, json : Json, indent : Int) -> Unit {
  match json {
    Null => buf.write_string("null")
    True => buf.write_string("true")
    False => buf.write_string("false")
    Number(n, ..) => buf.write_string(n.to_string())
    String(s) => {
      buf.write_char('"')
      for c in s {
        match c {
          '"' => buf.write_string("\\\"")
          '\\' => buf.write_string("\\\\")
          '\n' => buf.write_string("\\n")
          '\r' => buf.write_string("\\r")
          '\t' => buf.write_string("\\t")
          _ => buf.write_char(c)
        }
      }
      buf.write_char('"')
    }
    Array(arr) =>
      if arr.is_empty() {
        buf.write_string("[]")
      } else {
        buf.write_string("[\n")
        let child = indent + 2
        for i, item in arr {
          write_indent(buf, child)
          json_write_pretty(buf, item, child)
          if i < arr.length() - 1 {
            buf.write_char(',')
          }
          buf.write_char('\n')
        }
        write_indent(buf, indent)
        buf.write_char(']')
      }
    Object(obj) =>
      if obj.is_empty() {
        buf.write_string("{}")
      } else {
        buf.write_string("{\n")
        let child = indent + 2
        let entries = obj.iter().collect()
        for i, pair in entries {
          let (k, v) = pair
          write_indent(buf, child)
          buf.write_char('"')
          buf.write_string(k)
          buf.write_string("\": ")
          json_write_pretty(buf, v, child)
          if i < entries.length() - 1 {
            buf.write_char(',')
          }
          buf.write_char('\n')
        }
        write_indent(buf, indent)
        buf.write_char('}')
      }
  }
}

///|
fn write_indent(buf : StringBuilder, n : Int) -> Unit {
  for _ in 0..<n {
    buf.write_char(' ')
  }
}

///|
/// Format an optional PID for display.
pub fn format_pid(pid : Int?) -> String {
  match pid {
    None => "-"
    Some(n) => n.to_string()
  }
}

///|
pub fn monitor_path(proc : String) -> String {
  "\{monitor_dir}/\{proc}"
}

///|
pub fn stdout_log_path(proc : String) -> String {
  "\{monitor_dir}/\{proc}/stdout.log"
}

///|
pub fn stderr_log_path(proc : String) -> String {
  "\{monitor_dir}/\{proc}/stderr.log"
}

///|
pub fn pid_file_path(proc : String) -> String {
  "\{monitor_dir}/\{proc}/pid"
}

///|
/// Ensure the monitor directory for a process exists.
pub fn ensure_monitor_dir(proc : String) -> Unit raise RedstartError {
  let dir = monitor_path(proc)
  if !@fs.path_exists(dir) {
    @fs.create_dir(dir) catch {
      e => raise RedstartError("failed to create monitor dir: \{@debug.to_repr(e)}")
    }
  }
}

///|
/// Ensure the root .redstart-monitor directory exists.
pub fn ensure_root_monitor_dir() -> Unit raise RedstartError {
  if !@fs.path_exists(monitor_dir) {
    @fs.create_dir(monitor_dir) catch {
      e => raise RedstartError("failed to create .redstart-monitor: \{@debug.to_repr(e)}")
    }
  }
}

///|
/// Create an empty Config.
pub fn new_config() -> Config {
  { version: "1", processes: [] }
}

///|
/// Create a new ProcessEntry in "stopped" state.
pub fn new_process_entry(
  id : String,
  proc_name : String,
  command : String,
  cwd : String?,
  env : Map[String, String],
  created_at : String,
) -> ProcessEntry {
  {
    id,
    proc_name,
    command,
    cwd,
    env,
    created_at,
    status: "stopped",
    pid: None,
    started_at: None,
    stopped_at: None,
    exit_code: None,
    retry_count: 0,
  }
}

///|
/// Check if the config file exists in the current directory.
pub fn config_file_exists() -> Bool {
  @fs.path_exists(config_file)
}

///|
/// Read the last N lines of a file.
pub fn read_last_lines(
  path : String,
  n : Int,
) -> Array[String] raise RedstartError {
  guard @fs.path_exists(path) else { return [] }
  let content = @fs.read_file_to_string(path) catch {
    e => raise RedstartError("failed to read \{path}: \{@debug.to_repr(e)}")
  }
  let all_lines = content.split("\n").map(StringView::to_owned).collect()
  // Remove trailing empty line if present
  let end = if !all_lines.is_empty() && all_lines.last().unwrap() == "" {
    all_lines.length() - 1
  } else {
    all_lines.length()
  }
  let trimmed = all_lines[0:end]
  if trimmed.length() <= n {
    trimmed.iter().collect()
  } else {
    trimmed[trimmed.length() - n:trimmed.length()].iter().collect()
  }
}
