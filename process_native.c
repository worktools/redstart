// Copyright 2026 tiye/redstart
//
// Native C FFI for process management on POSIX systems.
// Provides: spawn (posix_spawn), kill, process-group kill, liveness checks, now.

#ifndef _WIN32

#ifdef __cplusplus
extern "C" {
#endif

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#include "moonbit.h"

// ---------------------------------------------------------------------------
// redstart_spawn
//
// Spawns a shell command as a detached background process using posix_spawn.
// This is the macOS-safe alternative to double-fork, as it avoids the
// fork()+exec() pattern that can fail in processes using GCD/ObjC runtimes.
//
// The spawned process is placed in its own process group (SETPGROUP) so it
// is detached from the caller's terminal.
//
// Parameters (all null-terminated UTF-8 strings via MoonBit Bytes + #borrow):
//   cmd         - shell command to execute via /bin/sh -c
//   cwd         - working directory (empty string = inherit current dir)
//   stdout_path - path to stdout log file (opened in append mode)
//   stderr_path - path to stderr log file (opened in append mode)
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT int32_t redstart_spawn(moonbit_bytes_t cmd,
                                          moonbit_bytes_t cwd,
                                          moonbit_bytes_t stdout_path,
                                          moonbit_bytes_t stderr_path) {
  // Open log files
  int out_fd = open((const char *)stdout_path,
                    O_WRONLY | O_CREAT | O_APPEND, 0644);
  int err_fd = open((const char *)stderr_path,
                    O_WRONLY | O_CREAT | O_APPEND, 0644);
  int null_fd = open("/dev/null", O_RDONLY);

  if (out_fd < 0 || err_fd < 0 || null_fd < 0) {
    if (out_fd >= 0) close(out_fd);
    if (err_fd >= 0) close(err_fd);
    if (null_fd >= 0) close(null_fd);
    return -1;
  }

  // Build file actions: redirect stdin/stdout/stderr
  posix_spawn_file_actions_t file_actions;
  posix_spawn_file_actions_init(&file_actions);
  posix_spawn_file_actions_adddup2(&file_actions, null_fd, STDIN_FILENO);
  posix_spawn_file_actions_adddup2(&file_actions, out_fd, STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&file_actions, err_fd, STDERR_FILENO);
  posix_spawn_file_actions_addclose(&file_actions, out_fd);
  posix_spawn_file_actions_addclose(&file_actions, err_fd);
  posix_spawn_file_actions_addclose(&file_actions, null_fd);

  // Spawn attrs: put process in its own process group (detach from terminal)
  posix_spawnattr_t spawnattr;
  posix_spawnattr_init(&spawnattr);
  posix_spawnattr_setflags(&spawnattr, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&spawnattr, 0); // new process group = child's pid

  // Change directory if cwd is specified (using a wrapper script)
  // We build the actual command: if cwd is non-empty, prepend "cd <cwd> && "
  char *full_cmd;
  const char *cwd_str = (const char *)cwd;
  const char *cmd_str = (const char *)cmd;
  if (strlen(cwd_str) > 0) {
    size_t len = strlen(cwd_str) + strlen(cmd_str) + 8;
    full_cmd = malloc(len);
    if (!full_cmd) {
      posix_spawn_file_actions_destroy(&file_actions);
      posix_spawnattr_destroy(&spawnattr);
      close(out_fd); close(err_fd); close(null_fd);
      return -1;
    }
    snprintf(full_cmd, len, "cd %s && %s", cwd_str, cmd_str);
  } else {
    full_cmd = (char *)cmd_str;
  }

  char *argv[] = { "/bin/sh", "-c", full_cmd, NULL };
  char *envp[] = { NULL }; // inherit env

  pid_t pid = -1;
  int rc = posix_spawn(&pid, "/bin/sh", &file_actions, &spawnattr, argv, environ);

  posix_spawn_file_actions_destroy(&file_actions);
  posix_spawnattr_destroy(&spawnattr);
  close(out_fd);
  close(err_fd);
  close(null_fd);
  if (strlen(cwd_str) > 0) free(full_cmd);

  if (rc != 0) {
    return -1;
  }
  return (int32_t)pid;
}

// ---------------------------------------------------------------------------
// redstart_kill
//
// Send a signal to a process.
// Returns 0 on success, -1 on error.
// Common signals: 15 (SIGTERM), 9 (SIGKILL)
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT int32_t redstart_kill(int32_t pid, int32_t sig) {
  return (int32_t)kill((pid_t)pid, sig);
}

// ---------------------------------------------------------------------------
// redstart_kill_process_group
//
// Send a signal to an entire process group.
// Returns 0 on success, -1 on error.
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT int32_t redstart_kill_process_group(int32_t pgid,
                                                       int32_t sig) {
  if (pgid <= 0) return -1;
  return (int32_t)kill(-(pid_t)pgid, sig);
}

// ---------------------------------------------------------------------------
// redstart_is_alive
//
// Check if a process is alive.
// Returns 1 if alive, 0 if not alive.
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT int32_t redstart_is_alive(int32_t pid) {
  if (pid <= 0) return 0;
  int result = kill((pid_t)pid, 0);
  if (result == 0) return 1;
  if (errno == EPERM) return 1; // process exists but we lack permission
  return 0;
}

// ---------------------------------------------------------------------------
// redstart_is_process_group_alive
//
// Check if any process in the process group is still alive.
// Returns 1 if alive, 0 if not alive.
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT int32_t redstart_is_process_group_alive(int32_t pgid) {
  if (pgid <= 0) return 0;
  int result = kill(-(pid_t)pgid, 0);
  if (result == 0) return 1;
  if (errno == EPERM) return 1; // process group exists but we lack permission
  return 0;
}

// ---------------------------------------------------------------------------
// redstart_write_process_group_snapshot
//
// Write current process-group members to a tab-separated snapshot file:
//   pid<TAB>ppid<TAB>pgid<TAB>command\n
// Returns 0 on success, -1 on error.
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT int32_t redstart_write_process_group_snapshot(
    int32_t pgid, moonbit_bytes_t output_path) {
  if (pgid <= 0) return -1;

  FILE *out = fopen((const char *)output_path, "w");
  if (!out) return -1;

  FILE *ps = popen("ps -axo pid=,ppid=,pgid=,command=", "r");
  if (!ps) {
    fclose(out);
    return -1;
  }

  char line[8192];
  while (fgets(line, sizeof(line), ps) != NULL) {
    char *cursor = line;
    while (*cursor == ' ' || *cursor == '\t') cursor++;
    if (*cursor == '\0' || *cursor == '\n') continue;

    errno = 0;
    char *end = NULL;
    long pid_value = strtol(cursor, &end, 10);
    if (end == cursor || errno != 0) continue;
    cursor = end;

    long ppid_value = strtol(cursor, &end, 10);
    if (end == cursor || errno != 0) continue;
    cursor = end;

    long pgid_value = strtol(cursor, &end, 10);
    if (end == cursor || errno != 0) continue;
    cursor = end;

    while (*cursor == ' ' || *cursor == '\t') cursor++;
    size_t command_len = strlen(cursor);
    while (command_len > 0 &&
           (cursor[command_len - 1] == '\n' || cursor[command_len - 1] == '\r')) {
      cursor[command_len - 1] = '\0';
      command_len--;
    }

    if (pgid_value != (long)pgid) continue;
    if (fprintf(out, "%ld\t%ld\t%ld\t%s\n", pid_value, ppid_value,
                pgid_value, cursor) < 0) {
      pclose(ps);
      fclose(out);
      return -1;
    }
  }

  int ps_status = pclose(ps);
  if (fclose(out) != 0) return -1;
  return ps_status == 0 ? 0 : -1;
}

// ---------------------------------------------------------------------------
// redstart_sleep_ms
//
// Sleep for the given number of milliseconds.
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT void redstart_sleep_ms(int32_t ms) {
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (ms % 1000) * 1000000L;
  nanosleep(&ts, NULL);
}

// ---------------------------------------------------------------------------
// redstart_now
//
// Return current Unix timestamp in seconds.
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT int64_t redstart_now(void) { return (int64_t)time(NULL); }

// ---------------------------------------------------------------------------
// redstart_get_exit_code
//
// Wait for process (non-blocking) and get exit code.
// Returns exit code (0-255) if process has exited, or -1 if still running.
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT int32_t redstart_get_exit_code(int32_t pid) {
  if (pid <= 0) return -1;
  int status;
  pid_t result = waitpid((pid_t)pid, &status, WNOHANG);
  if (result == 0) return -1;     // still running
  if (result < 0) return -1;      // error
  if (WIFEXITED(status)) {
    return (int32_t)WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    return (int32_t)(128 + WTERMSIG(status));
  }
  return -1;
}

#ifdef __cplusplus
}
#endif

#endif // _WIN32
