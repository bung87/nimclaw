import std/[os, times]
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

# Initialize logger - sets the log file path to OS-specific location
proc initLogger*() =
  let logDir = getDefaultLogDir()
  if not dirExists(logDir):
    try:
      createDir(logDir)
    except CatchableError:
      discard

  let dateStr = now().format("yyyy-MM-dd")
  let logFile = logDir / "nimclaw-" & dateStr & ".log"
  discard defaultChroniclesStream.outputs[0].open(logFile, fmAppend)
