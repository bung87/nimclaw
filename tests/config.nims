# Test configuration
# Add project root to path so tests can import nimclaw modules
switch("path", "$projectDir/../src")

# Same logging level as main project
switch("define", "chronicles_log_level=ERROR")
