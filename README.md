# NimClaw 🦞

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Nim Version](https://img.shields.io/badge/nim-%3E%3D2.0.0-orange.svg)](https://nim-lang.org)
[![CI](https://github.com/bung87/nimclaw/actions/workflows/ci.yml/badge.svg)](https://github.com/bung87/nimclaw/actions/workflows/ci.yml)
[![GitHub stars](https://img.shields.io/github/stars/bung87/nimclaw?style=social)](https://github.com/bung87/nimclaw/stargazers)

Ultra-efficient AI assistant in Nim. A high-performance implementation inspired by PicoClaw.

## Features
- Independent implementations of all channels (Telegram, Discord, QQ, Feishu, DingTalk, WhatsApp, MaixCam).
- Powerful toolset: filesystem, shell, web, cron, spawn.
- <10MB RAM footprint.
- Zero heavy dependencies for channels.

## Installation

### Prerequisites
- Nim >= 2.0.0
- nimble

### Build from Source

```bash
# Clone the repository
git clone https://github.com/bung87/nimclaw.git
cd nimclaw

# Install dependencies and build
nimble build -d:release

# Or compile directly
nim c -d:release src/nimclaw.nim
```

### Quick Start

```bash
# 1. Initialize configuration
./nimclaw onboard

# 2. Edit config at ~/.picoclaw/config.json
#    Add your LLM API keys (OpenAI, Anthropic, OpenRouter, etc.)
#    Enable desired channels (Telegram, Discord, etc.)

# 3. Start the gateway (all enabled channels)
./nimclaw gateway

# 4. Or use interactive CLI mode
./nimclaw agent "Hello, what can you do?"
```

### Commands

| Command | Description |
|---------|-------------|
| `onboard` | Create initial configuration |
| `agent [message]` | Run interactive agent or single query |
| `gateway` | Start message gateway with all channels |

### Configuration

Edit `~/.picoclaw/config.json`:

```json
{
  "agents": {
    "defaults": {
      "model": "gpt-4",
      "max_tokens": 8192
    }
  },
  "providers": {
    "openai": {
      "api_key": "sk-..."
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "token": "YOUR_BOT_TOKEN"
    }
  }
}
```
