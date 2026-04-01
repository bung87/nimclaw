import chronos
import std/[os, strutils, tables, options]
import cligen
import nimclaw/[config, logger, bus, agent/loop, providers/factory, tui/core as tui_core]
import nimclaw/channels/[manager as channel_manager, base as channel_base]
import nimclaw/services/[heartbeat, cron as cron_service, voice]
import nimclaw/skills/[loader as skills_loader, installer as skills_installer]

const version = "0.1.0"
const logo = "🦞"

proc getConfigPath(): string =
  getHomeDir() / ".picoclaw" / "config.json"

proc createWorkspaceTemplates(workspace: string) =
  let templates = {
    "AGENTS.md": "# Agent Instructions\nYou are a helpful AI assistant.\n",
    "SOUL.md": "# Soul\nI am picoclaw.\n",
    "USER.md": "# User\n",
    "IDENTITY.md": "# Identity\nName: PicoClaw 🦞\n"
  }.toTable
  for filename, content in templates:
    let filePath = workspace / filename
    if not fileExists(filePath): writeFile(filePath, content)
  if not dirExists(workspace / "memory"): createDir(workspace / "memory")
  if not fileExists(workspace / "memory" / "MEMORY.md"):
    writeFile(workspace / "memory" / "MEMORY.md", "# Long-term Memory\n")

proc onboard() =
  initLogger()
  let configPath = getConfigPath()
  if fileExists(configPath):
    stdout.write "Overwrite? (y/n): "
    if stdin.readLine().toLowerAscii != "y": return
  let cfg = defaultConfig()
  saveConfig(configPath, cfg)
  let workspace = cfg.workspacePath()
  createDir(workspace)
  createDir(workspace / "memory"); createDir(workspace / "skills")
  createDir(workspace / "sessions"); createDir(workspace / "cron")
  createWorkspaceTemplates(workspace)
  echo logo, " picoclaw is ready!"

proc agent(message = "", session = "cli:default") =
  initLogger()
  let cfg = loadConfig(getConfigPath())
  let agentLoop = newAgentLoop(cfg, newMessageBus(), createProvider(cfg))
  if message != "":
    # One-shot mode
    echo logo, " ", waitFor agentLoop.processDirect(message, session)
  else:
    # TUI mode (default)
    setControlCHook(tui_core.cleanup)
    let app = newTuiApp(agentLoop, cfg)
    waitFor app.run()

proc gateway() =
  initLogger()
  let cfg = loadConfig(getConfigPath())
  let msgBus = newMessageBus()
  let agentLoop = newAgentLoop(cfg, msgBus, createProvider(cfg))
  let chanManager = newManager(cfg, msgBus); chanManager.initChannels()
  if cfg.providers.groq.api_key != "":
    let transcriber = newGroqTranscriber(cfg.providers.groq.api_key)
    for name in ["telegram", "discord"]:
      let (ch, ok) = chanManager.getChannel(name)
      if ok: ch.setTranscriber(transcriber)
  let hbService = newHeartbeatService(cfg.workspacePath(), proc(p: string): Future[void] {.async.} =
    discard await agentLoop.processDirect(p, "system:heartbeat")
  , 1800, true)
  echo logo, " Starting Gateway..."
  waitFor chanManager.startAll(); waitFor hbService.start()
  echo logo, " Gateway started. Press Ctrl+C to stop."
  while true: poll()

proc status() =
  let configPath = getConfigPath()
  echo logo, " picoclaw Status\nConfig: ", configPath, if fileExists(configPath): " ✓" else: " ✗"

proc cron(list = false, add = false, remove = "", enable = "", disable = "",
          name = "", message = "", every = 0, at = 0.0, cron_expr = "",
          deliver = true, channel = "", to = "") =
  let cfg = loadConfig(getConfigPath())
  let cs = newCronService(cfg.workspacePath() / "cron" / "jobs.json", nil)
  if list:
    for j in cs.listJobs(true): echo "$1 ($2) - $3".format(j.name, j.id, j.schedule.kind)
  elif add:
    var sched: CronSchedule
    if every > 0: sched = CronSchedule(kind: "every", everyMs: some(every.int64 * 1000))
    elif at > 0: sched = CronSchedule(kind: "at", atMs: some(at.int64))
    elif cron_expr != "": sched = CronSchedule(kind: "cron", expr: cron_expr)
    else: (echo "Error: every, at, or cron_expr required"; return)
    let job = waitFor cs.addJob(name, sched, message, deliver, channel, to)
    echo "Added job: ", job.id
  elif remove != "":
    if cs.removeJob(remove): echo "Removed job ", remove
  elif enable != "": discard cs.enableJob(enable, true)
  elif disable != "": discard cs.enableJob(disable, false)

proc skills(list = false, install = "", remove = "", show = "", create = "",
            description = "", from_path = "", verbose = false) =
  let cfg = loadConfig(getConfigPath())
  let workspace = cfg.workspacePath()
  let installer = newSkillInstaller(workspace)
  let loader = newSkillsLoader(workspace, "", "")

  # Set verbose mode
  installer.verbose = verbose

  if list:
    let installed = installer.listInstalledSkills()
    if installed.len == 0:
      echo "No skills installed. Use --install or --create to add skills."
    else:
      echo "Installed skills:"
      for s in installed: echo "  ✓ ", s
  elif create != "":
    try:
      let path = installer.createSkill(create, description)
      echo "Created skill at: ", path
    except IOError as e:
      echo "Error: ", e.msg
  elif install != "":
    # Install from GitHub (format: owner/repo)
    try:
      let name = installer.installFromGitHub(install)
      echo "Installed skill from GitHub: ", name
    except IOError as e:
      echo "Error: ", e.msg
  elif from_path != "":
    # Install from local path
    try:
      let name = installer.installFromPath(from_path)
      echo "Installed skill: ", name
    except IOError as e:
      echo "Error: ", e.msg
  elif remove != "":
    try:
      installer.uninstall(remove)
      echo "Removed skill: ", remove
    except IOError as e:
      echo "Error: ", e.msg
  elif show != "":
    let (c, ok) = loader.loadSkill(show)
    if ok: echo c
    else: echo "Skill not found: ", show

when isMainModule:
  dispatchMulti([onboard], [agent], [gateway], [status], [cron], [skills])
