import chronos
import std/[tables, locks, strutils]
import base as channel_base
import telegram, discord, whatsapp, dingtalk, maixcam, feishu, qq
import ../bus, ../bus_types, ../config, ../logger

type
  Manager* = ref object
    channels*: Table[string, channel_base.Channel]
    bus*: MessageBus
    config*: Config
    lock*: Lock
    running*: bool

proc newManager*(cfg: Config, messageBus: MessageBus): Manager =
  Manager(
    channels: initTable[string, channel_base.Channel](),
    bus: messageBus,
    config: cfg
  )

proc initChannels*(m: Manager) =
  info "Initializing channel manager", topic = "channels"

  if m.config.channels.telegram.enabled and m.config.channels.telegram.token != "":
    m.channels["telegram"] = newTelegramChannel(m.config.channels.telegram, m.bus)

  if m.config.channels.discord.enabled and m.config.channels.discord.token != "":
    m.channels["discord"] = newDiscordChannel(m.config.channels.discord, m.bus)

  if m.config.channels.whatsapp.enabled and m.config.channels.whatsapp.bridge_url != "":
    m.channels["whatsapp"] = newWhatsAppChannel(m.config.channels.whatsapp, m.bus)

  if m.config.channels.dingtalk.enabled:
    m.channels["dingtalk"] = newDingTalkChannel(m.config.channels.dingtalk, m.bus)

  if m.config.channels.maixcam.enabled:
    m.channels["maixcam"] = newMaixCamChannel(m.config.channels.maixcam, m.bus)

  if m.config.channels.feishu.enabled:
    m.channels["feishu"] = newFeishuChannel(m.config.channels.feishu, m.bus)

  if m.config.channels.qq.enabled:
    m.channels["qq"] = newQQChannel(m.config.channels.qq, m.bus)

  info "Channel initialization completed", topic = "channels", enabled_channels = $m.channels.len

proc dispatchOutbound(m: Manager) {.async.} =
  info "Outbound dispatcher started", topic = "channels"
  while m.running:
    let msg = await m.bus.subscribeOutbound()
    if m.channels.hasKey(msg.channel):
      let channel = m.channels[msg.channel]
      try:
        await channel.send(msg)
      except CatchableError as e:
        error "Error sending message to channel", topic = "channels", channel = msg.channel, error = e.msg
    else:
      warn "Unknown channel for outbound message", topic = "channels", channel = msg.channel

proc startAll*(m: Manager) {.async.} =
  if m.channels.len == 0:
    warn "No channels enabled", topic = "channels"
    return

  m.running = true
  discard dispatchOutbound(m)

  for name, channel in m.channels:
    info "Starting channel", topic = "channels", channel = name
    try:
      await channel.start()
    except CatchableError as e:
      error "Failed to start channel", topic = "channels", channel = name, error = e.msg

proc stopAll*(m: Manager) {.async.} =
  m.running = false
  for name, channel in m.channels:
    info "Stopping channel", topic = "channels", channel = name
    try:
      await channel.stop()
    except CatchableError as e:
      error "Error stopping channel", topic = "channels", channel = name, error = e.msg

proc getEnabledChannels*(m: Manager): seq[string] =
  for k in m.channels.keys: result.add(k)

proc getChannel*(m: Manager, name: string): (channel_base.Channel, bool) =
  if m.channels.hasKey(name): (m.channels[name], true) else: (nil, false)
