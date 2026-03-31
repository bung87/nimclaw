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

# Output to stdout (console)
# switch("define", "chronicles_sinks=textlines[stdout]")

# For file logging, use:
  switch("define", "chronicles_sinks=textlines[file]")
#   switch("define", "chronicles_file=path/to/nimclaw.log")
#
# Or for both console and file:
#   switch("define", "chronicles_sinks=textlines[stdout],textlines[file]")
#
# Log rotation is handled by external tools like logrotate on Linux,
# or use the nimclaw built-in rotation by setting chronicles_file to a
# date-based path at startup.

# Timestamp format: RfcTime, RfcUtcTime, UnixTime, or NoTimestamps
switch("define", "chronicles_timestamps=RfcTime")

# Disable thread ID in log output
switch("define", "chronicles_thread_ids=no")
