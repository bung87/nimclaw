import chronos
import chronos/apps/http/httpclient
import std/[json, strutils, tables, os]
import pkg/regex except re
import base
import ../bus, ../bus_types, ../config, ../logger, ../services/voice

type
  TelegramChannel* = ref object of BaseChannel
    token*: string
    lastUpdateID: int
    transcriber*: GroqTranscriber
    placeholders: Table[string, int] # chatID -> messageID
    stopThinking: Table[string, bool] # chatID -> stopped
    session*: HttpSessionRef

proc markdownToTelegramHTML(text: string): string =
  if text == "": return ""
  # Basic markdown to HTML conversion as in Go logic
  var res = text
  res = res.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
  # Very basic regex based replacements for bold, italic etc.
  res = res.replace(re2("\\[([^\\]]+)\\]\\(([^)]+)\\)"), "<a href=\"$2\">$1</a>")
  res = res.replace(re2("\\*\\*(.+?)\\*\\*"), "<b>$1</b>")
  res = res.replace(re2("__(.+?)__"), "<b>$1</b>")
  res = res.replace(re2("_([^_]+)_"), "<i>$1</i>")
  res = res.replace(re2("~~(.+?)~~"), "<s>$1</s>")
  res = res.replace(re2("(?m)^[-*]\\s+"), "• ")
  return res

proc newTelegramChannel*(cfg: TelegramConfig, bus: MessageBus): TelegramChannel =
  let base = newBaseChannel("telegram", bus, cfg.allow_from)
  TelegramChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    token: cfg.token,
    lastUpdateID: 0,
    placeholders: initTable[string, int](),
    stopThinking: initTable[string, bool](),
    session: HttpSessionRef.new()
  )

method setTranscriber*(c: TelegramChannel, transcriber: GroqTranscriber) =
  c.transcriber = transcriber

proc apiCall(c: TelegramChannel, method_name: string, payload: JsonNode): Future[JsonNode] {.async.} =
  var headers: seq[HttpHeaderTuple] = @[
    (key: "Content-Type", value: "application/json")
  ]
  let url = "https://api.telegram.org/bot$1/$2".format(c.token, method_name)
  
  let addressRes = c.session.getAddress(url)
  if addressRes.isErr:
    errorCF("telegram", "Failed to resolve URL", {"url": url}.toTable)
    return %*{"ok": false}
  let address = addressRes.get()
  
  let bodyStr = $payload
  let request = HttpClientRequestRef.new(
    c.session,
    address,
    meth = MethodPost,
    headers = headers,
    body = bodyStr.toOpenArrayByte(0, bodyStr.len - 1)
  )
  
  var response: HttpClientResponseRef = nil
  try:
    response = await request.send()
    let bodyBytes = await response.getBodyBytes()
    await response.closeWait()
    response = nil
    let body = cast[string](bodyBytes)
    let json = parseJson(body)
    if not json["ok"].getBool():
      errorCF("telegram", "API error", {"method": method_name, "error": json.getOrDefault("description").getStr()}.toTable)
    return json
  except CatchableError as e:
    if not isNil(response):
      await response.closeWait()
    errorCF("telegram", "Request failed", {"method": method_name, "error": e.msg}.toTable)
    return %*{"ok": false}

proc downloadFile(c: TelegramChannel, fileID: string, ext: string): Future[string] {.async.} =
  let res = await c.apiCall("getFile", %*{"file_id": fileID})
  if not res["ok"].getBool(): return ""
  let filePath = res["result"]["file_path"].getStr()
  let url = "https://api.telegram.org/file/bot$1/$2".format(c.token, filePath)

  let addressRes = c.session.getAddress(url)
  if addressRes.isErr: return ""
  let address = addressRes.get()
  
  let request = HttpClientRequestRef.new(
    c.session,
    address,
    meth = MethodGet
  )
  
  var response: HttpClientResponseRef = nil
  try:
    response = await request.send()
    let status = response.status
    let bodyBytes = await response.getBodyBytes()
    await response.closeWait()
    response = nil
    if status == 200:
      let mediaDir = getTempDir() / "picoclaw_media"
      if not dirExists(mediaDir): createDir(mediaDir)
      let localPath = mediaDir / (fileID[0..min(15, fileID.len-1)] & ext)
      writeFile(localPath, cast[string](bodyBytes))
      return localPath
  except CatchableError:
    if not isNil(response):
      await response.closeWait()
  return ""

proc handleTelegramUpdate(c: TelegramChannel, update: JsonNode) {.async.} =
  if not update.hasKey("message"): return
  let msg = update["message"]
  if not msg.hasKey("from"): return

  let user = msg["from"]
  var senderID = $user["id"].getBiggestInt()
  if user.hasKey("username"):
    senderID = senderID & "|" & user["username"].getStr()

  let chatID = $msg["chat"]["id"].getBiggestInt()

  var content = ""
  if msg.hasKey("text"): content.add(msg["text"].getStr())
  if msg.hasKey("caption"):
    if content != "": content.add("\n")
    content.add(msg["caption"].getStr())

  var mediaPaths: seq[string] = @[]

  if msg.hasKey("photo"):
    let photos = msg["photo"]
    let photo = photos[photos.len - 1]
    let path = await c.downloadFile(photo["file_id"].getStr(), ".jpg")
    if path != "":
      mediaPaths.add(path)
      if content != "": content.add("\n")
      content.add("[image: $1]".format(path))

  if msg.hasKey("voice"):
    let voice = msg["voice"]
    let path = await c.downloadFile(voice["file_id"].getStr(), ".ogg")
    if path != "":
      mediaPaths.add(path)
      var transcribed = "[voice: $1]".format(path)
      if c.transcriber != nil:
        try:
          let res = await c.transcriber.transcribe(path)
          transcribed = "[voice transcription: $1]".format(res.text)
        except: discard
      if content != "": content.add("\n")
      content.add(transcribed)

  if content == "": content = "[empty message]"

  # Thinking animation
  discard await c.apiCall("sendChatAction", %*{"chat_id": chatID, "action": "typing"})
  let pMsg = await c.apiCall("sendMessage", %*{"chat_id": chatID, "text": "Thinking... 💭"})
  if pMsg["ok"].getBool():
    let pID = pMsg["result"]["message_id"].getInt()
    c.placeholders[chatID] = pID
    c.stopThinking[chatID] = false

    discard (proc() {.async.} =
      let dots = [".", "..", "..."]
      let emotes = ["💭", "🤔", "☁️"]
      var i = 0
      while c.stopThinking.hasKey(chatID) and not c.stopThinking[chatID]:
        await sleepAsync(2000)
        if not c.stopThinking.hasKey(chatID) or c.stopThinking[chatID]: break
        i += 1
        let text = "Thinking" & dots[i mod dots.len] & " " & emotes[i mod emotes.len]
        discard await c.apiCall("editMessageText", %*{"chat_id": chatID, "message_id": c.placeholders[chatID], "text": text})
    )()

  try:
    c.handleMessage(senderID, chatID, content, mediaPaths)
  except Exception as e:
    errorCF("telegram", "Failed to handle message", {"error": e.msg}.toTable)

proc poll(c: TelegramChannel) {.async.} =
  while c.running:
    try:
      let res = await c.apiCall("getUpdates", %*{"offset": c.lastUpdateID + 1, "timeout": 30})
      if res["ok"].getBool():
        for update in res["result"]:
          c.lastUpdateID = update["update_id"].getInt()
          discard handleTelegramUpdate(c, update)
    except Exception as e:
      errorCF("telegram", "Polling error", {"error": e.msg}.toTable)
      await sleepAsync(5000)

method name*(c: TelegramChannel): string = "telegram"

method start*(c: TelegramChannel) {.async.} =
  infoC("telegram", "Starting Telegram bot (raw mode)...")
  let me = await c.apiCall("getMe", %*{})
  if me["ok"].getBool():
    infoCF("telegram", "Telegram bot connected", {"username": me["result"]["username"].getStr()}.toTable)
    c.running = true
    discard poll(c)

method stop*(c: TelegramChannel) {.async.} =
  c.running = false
  if c.session != nil:
    await c.session.closeWait()
    c.session = nil

method send*(c: TelegramChannel, msg: OutboundMessage) {.async.} =
  if not c.running: return

  c.stopThinking[msg.chat_id] = true
  let htmlContent = markdownToTelegramHTML(msg.content)

  if msg.chat_id in c.placeholders:
    let pID = c.placeholders[msg.chat_id]
    c.placeholders.del(msg.chat_id)
    let editRes = await c.apiCall("editMessageText", %*{
      "chat_id": msg.chat_id,
      "message_id": pID,
      "text": htmlContent,
      "parse_mode": "HTML"
    })
    if editRes["ok"].getBool(): return

  discard await c.apiCall("sendMessage", %*{
    "chat_id": msg.chat_id,
    "text": htmlContent,
    "parse_mode": "HTML"
  })

method isRunning*(c: TelegramChannel): bool = c.running
