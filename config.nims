switch("define", "ssl")

when defined(macosx):
  when defined(arm64):
    switch("passC", "-arch arm64")
    switch("passL", "-arch arm64")
  when defined(amd64):
    switch("passC", "-arch x86_64")
    switch("passL", "-arch x86_64")

# Chronicles logging configuration
# Log level: DEBUG, INFO, WARN, ERROR, FATAL
# switch("define", "chronicles_log_level=INFO")

# Output to both console and file
switch("define", "chronicles_sinks=textlines[stdout],textlines[file]")

# Enable file rotation - max 5 files, 10MB each
switch("define", "chronicles_rotate=5")
switch("define", "chronicles_max_size=10485760")  # 10MB

# Disable thread ID in log output for cleaner console output
switch("define", "chronicles_thread_ids=no")

# Enable timestamps
switch("define", "chronicles_timestamps=RfcTime")

# File output directory is set at runtime via the LOG_DIR env variable
# or defaults to OS-specific location:
#   Windows: %APPDATA%/nimclaw/logs/
#   macOS: ~/Library/Logs/nimclaw/
#   Linux: ~/.local/share/nimclaw/logs/ or $XDG_DATA_HOME/nimclaw/logs/
