# NimClaw 🦞

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Nim Version](https://img.shields.io/badge/nim-%3E%3D2.0.0-orange.svg)](https://nim-lang.org)
[![Tests](https://github.com/bung87/nimclaw/actions/workflows/test.yml/badge.svg)](https://github.com/bung87/nimclaw/actions)
[![GitHub stars](https://img.shields.io/github/stars/bung87/nimclaw?style=social)](https://github.com/bung87/nimclaw/stargazers)

Ultra-Efficient AI Assistant in Nim it is in Progress

NimClaw is a complete, high-performance clone of PicoClaw.

## Features
- Independent implementations of all channels (Telegram, Discord, QQ, Feishu, DingTalk, WhatsApp, MaixCam).
- Powerful toolset: filesystem, shell, web, cron, spawn.
- <10MB RAM footprint.
- Zero heavy dependencies for channels.

## Usage
1. `nimble install -y jsony cligen ws regex`
2. `nim c -d:release src/nimclaw.nim`
3. `./src/nimclaw onboard`
4. `./src/nimclaw agent`
