// Stub implementations for non-native targets (wasm-gc, js, wasm).
// These allow moon check/publish to succeed; the real implementations
// are in process_native.mbt and only compiled for native/llvm targets.

///|
pub fn now() -> Int64 {
  panic()
}

///|
pub fn sleep_ms(_ms : Int) -> Unit {
  panic()
}

///|
pub fn spawn_process(
  _command : String,
  _cwd : String,
  _stdout_path : String,
  _stderr_path : String,
) -> Int? {
  panic()
}

///|
pub fn is_process_alive(_pid : Int) -> Bool {
  panic()
}

///|
pub fn kill_process(_pid : Int) -> Bool {
  panic()
}

///|
pub fn force_kill_process(_pid : Int) -> Bool {
  panic()
}

///|
pub fn list_process_group_members(
  _proc : String,
  _pgid : Int,
) -> Array[ProcessGroupMember] raise RedstartError {
  raise RedstartError("not supported on this target")
}

///|
pub fn is_process_group_alive(_pgid : Int) -> Bool {
  panic()
}

///|
pub fn find_live_process_group_pid(_entry : ProcessEntry) -> Int? {
  panic()
}

///|
pub fn inspect_process_runtime(
  entry : ProcessEntry,
) -> ProcessRuntimeDiagnostics {
  {
    tracked_pid: entry.pid,
    tracked_pid_alive: false,
    process_group_alive: false,
    pid_file_pid: None,
    pid_file_alive: false,
    cwd_exists: process_cwd_exists(entry),
    anomalies: [],
  }
}

///|
pub fn inspect_process(entry : ProcessEntry) -> ProcessInspectSnapshot {
  {
    process: entry,
    runtime: inspect_process_runtime(entry),
    process_group_members: [],
    child_processes: [],
  }
}

///|
pub fn start_with_retry(
  _entry : ProcessEntry,
  _max_retries : Int,
) -> (Int, String) raise RedstartError {
  raise RedstartError("not supported on this target")
}

///|
pub fn stop_gracefully(_pid : Int) -> Unit {
  panic()
}
