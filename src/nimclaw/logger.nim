import std/os
import chronicles

export chronicles

# OS-specific log directory
proc getDefaultLogDir*(): string =
  when defined(windows):
    getEnv("APPDATA") / "nimclaw" / "logs"
  elif defined(macosx):
    getHomeDir() / "Library" / "Logs" / "nimclaw"
  else:
    let xdgDataHome = getEnv("XDG_DATA_HOME")
    if xdgDataHome != "":
      xdgDataHome / "nimclaw" / "logs"
    else:
      getHomeDir() / ".local" / "share" / "nimclaw" / "logs"

# Initialize logger (creates log directory)
proc initLogger*(logDir: string = "") =
  let path = if logDir == "": getDefaultLogDir() else: logDir
  if not dirExists(path):
    try:
      createDir(path)
    except CatchableError:
      discard
