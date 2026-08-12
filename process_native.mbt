// Native-only FFI declarations for process management.
// This file is only compiled for native/llvm backends.

///|
/// Convert a MoonBit String to null-terminated UTF-8 Bytes for C FFI.
fn str_to_cstr(s : String) -> Bytes {
  let arr : Array[Byte] = []
  for c in s {
    let cp = c.to_int()
    if cp < 0x80 {
      arr.push(cp.to_byte())
    } else if cp < 0x800 {
      arr.push(((cp >> 6) | 0xC0).to_byte())
      arr.push(((cp & 0x3F) | 0x80).to_byte())
    } else if cp < 0x10000 {
      arr.push(((cp >> 12) | 0xE0).to_byte())
      arr.push((((cp >> 6) & 0x3F) | 0x80).to_byte())
      arr.push(((cp & 0x3F) | 0x80).to_byte())
    } else {
      arr.push(((cp >> 18) | 0xF0).to_byte())
      arr.push((((cp >> 12) & 0x3F) | 0x80).to_byte())
      arr.push((((cp >> 6) & 0x3F) | 0x80).to_byte())
      arr.push(((cp & 0x3F) | 0x80).to_byte())
    }
  }
  arr.push(b'\x00')
  Bytes::from_array(arr)
}

///|
#borrow(cmd, cwd, stdout_path, stderr_path)
extern "C" fn ffi_spawn(
  cmd : Bytes,
  cwd : Bytes,
  stdout_path : Bytes,
  stderr_path : Bytes,
) -> Int = "redstart_spawn"

///|
extern "C" fn ffi_kill(pid : Int, sig : Int) -> Int = "redstart_kill"

///|
extern "C" fn ffi_kill_process_group(pgid : Int, sig : Int) -> Int = "redstart_kill_process_group"

///|
extern "C" fn ffi_is_alive(pid : Int) -> Int = "redstart_is_alive"

///|
extern "C" fn ffi_is_process_group_alive(pgid : Int) -> Int = "redstart_is_process_group_alive"

///|
#borrow(output_path)
extern "C" fn ffi_write_process_group_snapshot(
  pgid : Int,
  output_path : Bytes,
) -> Int = "redstart_write_process_group_snapshot"

///|
extern "C" fn ffi_sleep_ms(ms : Int) -> Unit = "redstart_sleep_ms"

///|
extern "C" fn ffi_now() -> Int64 = "redstart_now"

///|
/// Get the current Unix timestamp in seconds.
pub fn now() -> Int64 {
  ffi_now()
}

///|
/// Sleep for ms milliseconds.
pub fn sleep_ms(ms : Int) -> Unit {
  ffi_sleep_ms(ms)
}

///|
/// Spawn a shell command as a background process.
/// Returns the PID on success, or None on failure.
pub fn spawn_process(
  command : String,
  cwd : String,
  stdout_path : String,
  stderr_path : String,
) -> Int? {
  let pid = ffi_spawn(
    str_to_cstr(command),
    str_to_cstr(cwd),
    str_to_cstr(stdout_path),
    str_to_cstr(stderr_path),
  )
  if pid <= 0 {
    None
  } else {
    Some(pid)
  }
}

///|
/// Check if a process with the given PID is alive.
pub fn is_process_alive(pid : Int) -> Bool {
  ffi_is_alive(pid) == 1
}

///|
/// Send SIGTERM (15) to a process.
pub fn kill_process(pid : Int) -> Bool {
  ffi_kill(pid, 15) == 0
}

///|
fn kill_process_group(pgid : Int) -> Bool {
  ffi_kill_process_group(pgid, 15) == 0
}

///|
/// Send SIGKILL (9) to a process.
pub fn force_kill_process(pid : Int) -> Bool {
  ffi_kill(pid, 9) == 0
}

///|
fn force_kill_process_group(pgid : Int) -> Bool {
  ffi_kill_process_group(pgid, 9) == 0
}

///|
pub fn is_process_group_alive(pgid : Int) -> Bool {
  ffi_is_process_group_alive(pgid) == 1
}

///|
fn parse_positive_int_or(s : String, default : Int) -> Int {
  let mut result = 0
  let mut seen_digit = false
  for c in s {
    let n = c.to_int()
    if n >= 48 && n <= 57 {
      result = result * 10 + n - 48
      seen_digit = true
    } else {
      return default
    }
  }
  if seen_digit {
    result
  } else {
    default
  }
}

///|
fn parse_process_group_member(line : String) -> ProcessGroupMember? {
  if line == "" {
    return None
  }
  let parts = line.split("\t").map(StringView::to_owned).collect()
  if parts.length() < 4 {
    return None
  }
  let pid = parse_positive_int_or(parts[0], -1)
  let ppid = parse_positive_int_or(parts[1], -1)
  let pgid = parse_positive_int_or(parts[2], -1)
  if pid <= 0 || ppid < 0 || pgid <= 0 {
    return None
  }
  let command = parts[3:parts.length()].join("\t")
  Some(new_process_group_member(pid, ppid, pgid, command))
}

///|
pub fn list_process_group_members(
  proc : String,
  pgid : Int,
) -> Array[ProcessGroupMember] raise RedstartError {
  if pgid <= 0 {
    return []
  }
  ensure_root_monitor_dir()
  ensure_monitor_dir(proc)
  let snapshot_path = process_group_snapshot_path(proc)
  let rc = ffi_write_process_group_snapshot(pgid, str_to_cstr(snapshot_path))
  if rc != 0 {
    raise RedstartError(
      "failed to inspect process group for '\{proc}' (pgid: \{pgid.to_string()})",
    )
  }
  let content = @fs.read_file_to_string(snapshot_path) catch {
    e =>
      raise RedstartError(
        "failed to read process-group snapshot: \{@debug.to_repr(e)}",
      )
  }
  let lines = content.split("\n").map(StringView::to_owned).collect()
  let members : Array[ProcessGroupMember] = []
  for line in lines {
    match parse_process_group_member(line) {
      None => ()
      Some(proc_info) => members.push(proc_info)
    }
  }
  members
}

///|
pub fn find_live_process_group_pid(entry : ProcessEntry) -> Int? {
  match entry.pid {
    Some(pid) if is_process_group_alive(pid) => Some(pid)
    _ =>
      match read_pid_file_or_none(entry.proc_name) {
        Some(pid) if is_process_group_alive(pid) => Some(pid)
        _ => None
      }
  }
}

///|
pub fn inspect_process_runtime(
  entry : ProcessEntry,
) -> ProcessRuntimeDiagnostics {
  let tracked_pid = entry.pid
  let cwd_exists = process_cwd_exists(entry)
  let tracked_pid_alive = match tracked_pid {
    None => false
    Some(pid) => is_process_alive(pid)
  }
  let process_group_alive = match tracked_pid {
    None => false
    Some(pid) => is_process_group_alive(pid)
  }
  let pid_file_pid = read_pid_file_or_none(entry.proc_name)
  let pid_file_alive = match pid_file_pid {
    None => false
    Some(pid) => is_process_group_alive(pid)
  }
  let anomalies : Array[String] = []
  match tracked_pid {
    None => {
      if entry.status == "running" {
        anomalies.push("status is 'running' but no pid is recorded in config")
      }
      if pid_file_alive {
        match pid_file_pid {
          None => ()
          Some(pid) =>
            anomalies.push(
              "config has no pid, but pid file points to live process group " +
              pid.to_string(),
            )
        }
      }
    }
    Some(pid) =>
      if !tracked_pid_alive && process_group_alive {
        anomalies.push(
          "tracked leader pid " +
          pid.to_string() +
          " exited, but the process group is still alive",
        )
      } else if !process_group_alive && entry.status == "running" {
        anomalies.push(
          "status is 'running' but tracked process group " +
          pid.to_string() +
          " is not alive",
        )
      }
  }
  match pid_file_pid {
    None => ()
    Some(pid) => {
      if !pid_file_alive {
        anomalies.push("pid file points to stale pid " + pid.to_string())
      }
      match tracked_pid {
        Some(saved_pid) if saved_pid != pid =>
          anomalies.push(
            "pid file pid " +
            pid.to_string() +
            " does not match tracked pid " +
            saved_pid.to_string(),
          )
        _ => ()
      }
    }
  }
  if !cwd_exists {
    match entry.cwd {
      None => ()
      Some(path) => anomalies.push("configured cwd does not exist: " + path)
    }
  }
  if entry.status != "running" && (process_group_alive || pid_file_alive) {
    anomalies.push(
      "status is '" +
      entry.status +
      "' but a process group still appears to be alive",
    )
  }
  {
    tracked_pid,
    tracked_pid_alive,
    process_group_alive,
    pid_file_pid,
    pid_file_alive,
    cwd_exists,
    anomalies,
  }
}

///|
pub fn inspect_process(entry : ProcessEntry) -> ProcessInspectSnapshot {
  let runtime = inspect_process_runtime(entry)
  let live_group_pid = find_live_process_group_pid(entry)
  let members = match live_group_pid {
    Some(pid) =>
      list_process_group_members(entry.proc_name, pid) catch {
        _ => []
      }
    None => []
  }
  let child_processes : Array[ProcessGroupMember] = []
  for proc_info in members {
    if proc_info.pid != proc_info.pgid {
      child_processes.push(proc_info)
    }
  }
  { process: entry, runtime, process_group_members: members, child_processes }
}

///|
/// Start a process with retry logic (up to max_retries attempts).
/// Returns (pid, timestamp) on success, raises RedstartError on failure.
pub fn start_with_retry(
  entry : ProcessEntry,
  max_retries : Int,
) -> (Int, String) raise RedstartError {
  if !process_cwd_exists(entry) {
    match entry.cwd {
      None => ()
      Some(path) =>
        raise RedstartError(
          "configured cwd does not exist for process '" +
          entry.proc_name +
          "': " +
          path,
        )
    }
  }
  let cwd = match entry.cwd {
    None => ""
    Some(d) => d
  }
  let stdout = stdout_log_path(entry.proc_name)
  let stderr = stderr_log_path(entry.proc_name)
  ensure_root_monitor_dir()
  ensure_monitor_dir(entry.proc_name)
  let mut attempt = 0
  while attempt < max_retries {
    attempt = attempt + 1
    match spawn_process(entry.command, cwd, stdout, stderr) {
      None => if attempt < max_retries { sleep_ms(1000) }
      Some(pid) => {
        // Wait 500ms and check if still alive
        sleep_ms(500)
        if is_process_alive(pid) {
          return (pid, now().to_string())
        } else if attempt < max_retries {
          sleep_ms(500)
        }
      }
    }
  }
  raise RedstartError(
    "failed to start process '\{entry.proc_name}' after \{max_retries} attempts",
  )
}

///|
/// Stop a process group gracefully (SIGTERM, then SIGKILL after timeout).
pub fn stop_gracefully(pid : Int) -> Unit {
  if pid <= 0 {
    return
  }
  ignore(kill_process_group(pid))
  // Poll up to 5 seconds (10 x 500ms) for the whole process group to exit.
  for _ in 0..<10 {
    sleep_ms(500)
    if !is_process_group_alive(pid) {
      return
    }
  }
  // Force kill the whole group if any child is still alive.
  if is_process_group_alive(pid) {
    ignore(force_kill_process_group(pid))
    for _ in 0..<10 {
      sleep_ms(100)
      if !is_process_group_alive(pid) {
        return
      }
    }
  }
}
