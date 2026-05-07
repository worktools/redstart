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
pub fn inspect_process(entry : ProcessEntry) -> ProcessInspectSnapshot {
  { process: entry, process_group_members: [], child_processes: [] }
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
