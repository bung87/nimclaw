import std/[os, times, strformat]
import chronicles

# Define our own LogLevel type alias
type LogLevel* = chronicles.LogLevel

const
  DEBUG* = LogLevel.DEBUG
  INFO* = LogLevel.INFO
  WARN* = LogLevel.WARN
  ERROR* = LogLevel.ERROR
  FATAL* = LogLevel.FATAL

var currentLevel* = INFO

# Set the current log level
proc setLevel*(level: LogLevel) =
  currentLevel = level

# Get the current log level
proc getLevel*(): LogLevel =
  return currentLevel

# Custom log template that matches the requested API:
# log(INFO, "message", topic = "topic", field = value)
template log*(level: LogLevel, msg: string, props: varargs[untyped]) =
  if level >= currentLevel:
    chronicles.log(instantiationInfo(), level, msg, props)

# OS-specific log directory
proc getDefaultLogDir*(): string =
  when defined(windows):
    getEnv("APPDATA") / "nimclaw" / "logs"
  elif defined(macosx):
    getHomeDir() / "Library" / "Logs" / "nimclaw"
  else: # Linux and other Unix-like
    let xdgDataHome = getEnv("XDG_DATA_HOME")
    if xdgDataHome != "":
      xdgDataHome / "nimclaw" / "logs"
    else:
      getHomeDir() / ".local" / "share" / "nimclaw" / "logs"

# Get log file path with date-based rotation
proc getLogFilePath*(logDir: string, appName: string = "nimclaw"): string =
  let dateStr = now().format("yyyy-MM-dd")
  logDir / fmt"{appName}-{dateStr}.log"

# Initialize logger with file output
proc initLogger*(logDir: string = "", appName: string = "nimclaw") =
  let logPath = if logDir == "": getDefaultLogDir() else: logDir
  
  if not dirExists(logPath):
    try:
      createDir(logPath)
    except CatchableError:
      discard
  
  let logFile = getLogFilePath(logPath, appName)
  putEnv("CHRONICLES_FILE", logFile)
  
  log(INFO, "Logger initialized", logDir = logPath, logFile = logFile)
