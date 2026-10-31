# AgentOS

[中文](README.md) | English

**AgentOS** is an autonomous mobile agent tweak running natively on jailbroken iOS devices.

It completely frees mobile automation from computer tethering (USB/WiFi ADB) and brittle pixel coordinates. Featuring a non-intrusive floating UI, it delivers a closed-loop workflow: **"Observation-based recording -> LLM semantic distillation -> Structured recipe persistence -> Dynamic runtime grounding & replay"**.

---

## 🌟 Key Features

- 📱 **Computer-Free & On-Device Closed Loop**: Directly drives on-device accessibility and control services via local loopback. Model reasoning and UI actions run entirely standalone on the iPhone.
- 👁️ **Observation-Only Recording**:
  - Non-intrusive: watches how the interface changes without hooking or intercepting user touch events.
  - Samples screen state via iOS Accessibility Tree (AXTree) supplemented by an embedded on-device PaddleOCR neural engine.
- 🧠 **LLM Semantic Distillation**:
  - Distills manual demonstrations into reusable recipes: entry steps, start conditions, loop logic, round completion triggers, exit criteria, and exception recovery rules.
  - **Zero Pixel Coordinates**: Grounded purely on visible text anchors and semantic intent. Resilient against UI shifts, resolution differences, font scaling, and randomized answer orders.
- 💡 **Dynamic Capsule State Machine & Haptics**:
  - **Idle**: Subtle cyan-green glow with minimalist `AI` emblem.
  - **Running**: Sky-blue border with smooth breathing pulse animations (0.85s cycle) clearly indicating background reasoning and actions.
  - **Done**: Transitions to emerald green with `✓ 完成` accompanied by Taptic success vibration feedback.
  - **Stopped / Error**: Transitions to alert orange with `! 停止` or `! 异常` and warning haptics.
  - **Auto-collapse on Run**: Tapping a skill chip immediately collapses the panel to keep the screen unobstructed.
- 💾 **Structured Skill Store**:
  - Stored as standard XML plists under `/var/mobile/Media/ios-deb/skills/` (survives tweak updates and allows effortless backup or cross-device sharing).
  - Tracks versions, run counts, and success rates displayed directly on chips.
- 🛡️ **Single-Task Safety Boundary**:
  - Discrete one-shot execution model. Clicking a skill runs strictly that task and halts completely upon completion—never auto-chains unexpected tasks.

---

## 🛠️ System Architecture

```text
┌────────────────────────────────────────────────────────┐
│                        AgentOS                         │
│                                                        │
│  ┌───────────────────┐        ┌─────────────────────┐  │
│  │ Floating Capsule  │        │ Observer & Recorder │  │
│  │ (Idle/Run/Done)   │        │ (AXTree + PaddleOCR)│  │
│  └────────┬──────────┘        └──────────┬──────────┘  │
│           │                              │             │
│           ▼                              ▼             │
│  ┌───────────────────┐        ┌─────────────────────┐  │
│  │    Skill Store    │◄───────┤ Distillation Engine │  │
│  │ (XML Plist Store) │        │ (Semantic Grounding)│  │
│  └────────┬──────────┘        └─────────────────────┘  │
│           │                                            │
│           ▼                                            │
│  ┌──────────────────────────────────────────────────┐  │
│  │ ReAct Executor (Perceive -> Think -> Act)        │  │
│  └────────────────────────┬─────────────────────────┘  │
└───────────────────────────┼────────────────────────────┘
                            ▼
      ┌───────────────────────────────────────────┐
      │ Local Loopback Services (http://127.0.0.1)│
      │   - AXTree inspection / Screen OCR        │
      │   - IOHID Touch / Hardware key injection  │
      │   - App & filesystem lifecycle controls   │
      └───────────────────────────────────────────┘
```

---

## 📦 Compatibility & Build Guide

### Requirements
- Jailbroken iOS device (iOS 13.0 - iOS 18.x)
- Supported schemes:
  - **RootHide** (`iphoneos-arm64e`)
  - **Rootless** (`iphoneos-arm64`)
  - **Rootful** (`iphoneos-arm`)

### Building (RootHide Example)

Ensure Theos environment is configured:

```bash
chmod +x build_roothide.sh
./build_roothide.sh
```

A `.deb` package (e.g. `com.witchan.ios-deb_2.0.0_iphoneos-arm64e.deb`) will be generated in `packages/`.

### Deployment

Install directly onto your device via `dpkg`:

```bash
dpkg -i com.witchan.ios-deb_2.0.0_iphoneos-arm64e.deb
killall -9 SpringBoard
```

---

## 📖 Quick Start

1. **Configure LLM**:
   - Navigate to iOS `Settings` -> `AgentOS`.
   - Enter your OpenAI-compatible endpoint, model name, and API Key (saved securely on device).
2. **Record a Skill**:
   - Tap the floating `AI` capsule to expand the panel.
   - Tap `● 录制` (Recording). The panel collapses automatically.
   - Perform the demonstration normally (e.g., answer 2-3 quiz questions).
   - Tap the capsule again and tap `■ 完成` (Finish).
   - Review the distilled recipe in the popup dialog and tap `保存` (Save).
3. **Replay Autonomously**:
   - Tap the newly created skill chip.
   - AgentOS will automatically collapse, pulse its breathing light, and autonomously complete subsequent rounds!

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
