import chronos
import chronos/apps/http/httpclient
import std/[json, strutils, os, tables, times]
import ../logger

type
  TranscriptionResponse* = object
    text*: string
    language*: string
    duration*: float64

  GroqTranscriber* = ref object
    apiKey*: string
    apiBase*: string
    session*: HttpSessionRef

proc newGroqTranscriber*(apiKey: string): GroqTranscriber =
  GroqTranscriber(
    apiKey: apiKey,
    apiBase: "https://api.groq.com/openai/v1",
    session: HttpSessionRef.new()
  )

proc isAvailable*(t: GroqTranscriber): bool =
  t.apiKey != ""

proc transcribe*(t: GroqTranscriber, audioFilePath: string): Future[TranscriptionResponse] {.async.} =
  info "Starting transcription", topic = "voice", audio_file = audioFilePath

  if not fileExists(audioFilePath):
    raise newException(IOError, "Audio file not found")

  let boundary = "----NimClawBoundary" & $getTime().toUnix
  var body = ""

  # Simplified multipart body construction
  body.add("--" & boundary & "\r\n")
  body.add("Content-Disposition: form-data; name=\"file\"; filename=\"" & lastPathPart(audioFilePath) & "\"\r\n")
  body.add("Content-Type: audio/mpeg\r\n\r\n")
  body.add(readFile(audioFilePath))
  body.add("\r\n")

  body.add("--" & boundary & "\r\n")
  body.add("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
  body.add("whisper-large-v3\r\n")

  body.add("--" & boundary & "--\r\n")

  var headers: seq[HttpHeaderTuple] = @[
    (key: "Content-Type", value: "multipart/form-data; boundary=" & boundary),
    (key: "Authorization", value: "Bearer " & t.apiKey)
  ]

  let url = t.apiBase & "/audio/transcriptions"
  
  let addressRes = t.session.getAddress(url)
  if addressRes.isErr:
    raise newException(IOError, "Failed to resolve URL")
  let address = addressRes.get()

  let request = HttpClientRequestRef.new(
    t.session,
    address,
    meth = MethodPost,
    headers = headers,
    body = body.toOpenArrayByte(0, body.len - 1)
  )

  let response = await request.send()
  let respBytes = await response.getBodyBytes()
  let respBody = cast[string](respBytes)

  if response.status != 200:
    error "API error", topic = "voice", status = $response.status, response = respBody
    raise newException(IOError, "API error: " & respBody)

  let result = parseJson(respBody).to(TranscriptionResponse)
  info "Transcription completed successfully", topic = "voice", text_length = $result.text.len
  return result
