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
extern "C" fn ffi_is_alive(pid : Int) -> Int = "redstart_is_alive"

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
/// Send SIGKILL (9) to a process.
pub fn force_kill_process(pid : Int) -> Bool {
  ffi_kill(pid, 9) == 0
}

///|
/// Start a process with retry logic (up to max_retries attempts).
/// Returns (pid, timestamp) on success, raises RedstartError on failure.
pub fn start_with_retry(
  entry : ProcessEntry,
  max_retries : Int,
) -> (Int, String) raise RedstartError {
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
/// Stop a process gracefully (SIGTERM, then SIGKILL after timeout).
pub fn stop_gracefully(pid : Int) -> Unit {
  ignore(kill_process(pid))
  // Poll up to 5 seconds (10 x 500ms)
  for _ in 0..<10 {
    sleep_ms(500)
    if !is_process_alive(pid) {
      return
    }
  }
  // Force kill if still alive
  if is_process_alive(pid) {
    ignore(force_kill_process(pid))
  }
}
