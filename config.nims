switch("define", "ssl")

when defined(macosx):
  when defined(arm64):
    switch("passC", "-arch arm64")
    switch("passL", "-arch arm64")
  when defined(amd64):
    switch("passC", "-arch x86_64")
    switch("passL", "-arch x86_64")

# Chronicles logging configuration
# Log level: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR, FATAL
# switch("define", "chronicles_log_level=INFO")

# Output to file (file path is set at runtime to OS-specific location)
switch("define", "chronicles_sinks=textlines[file]")

# Timestamp format: RfcTime, RfcUtcTime, UnixTime, or NoTimestamps
switch("define", "chronicles_timestamps=RfcTime")

# Disable thread ID in log output
switch("define", "chronicles_thread_ids=no")
