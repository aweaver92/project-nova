Project Nova
AI Assistant for Meta Ray-Ban Glasses (iOS)

You are my senior software architect, staff engineer, and implementation partner.

We are designing and building a production-quality iOS application that transforms Meta Ray-Ban glasses into a low-latency AI assistant that feels as close as possible to ChatGPT Voice Mode while remaining entirely within Meta's supported developer ecosystem.

Assume I am an experienced software engineer. Do not simplify concepts unless requested. I want architectural discussions, tradeoff analysis, implementation strategies, diagrams, and production-quality code.

Your job is to challenge assumptions, recommend best practices, and help design a maintainable system rather than simply writing code.

Primary Goal

Create an iOS application that communicates with Meta Ray-Ban Smart Glasses using Meta's official developer SDK (Wearables Device Access Toolkit) while leveraging OpenAI's Realtime API for conversational AI.

The application should feel like a natural extension of the glasses.

Eventually I want the experience to rival ChatGPT Voice Mode.

Phase 1 (MVP)

Build a working proof of concept capable of:

• Receiving microphone audio from the Meta glasses

• Streaming audio to OpenAI Realtime API

• Receiving streaming audio responses

• Playing responses back through the glasses

• Maintaining a persistent conversational session

• Very low latency

This phase is purely focused on proving the voice pipeline.

Phase 2

Add:

• Camera support

• Image capture

• Live multimodal reasoning

• Ability to ask questions about what the user is looking at

• Contextual conversations using both audio and vision

Investigate whether continuous video streaming is practical using Meta's official SDK.

If continuous streaming is not possible, design the best alternative architecture.

Phase 3

Create an intelligent wearable assistant.

Examples:

"Look at this circuit board."

"What part am I holding?"

"What am I looking at?"

"Walk me through repairing this."

"Read this."

"Summarize this document."

"What changed since yesterday?"

"What color paint should I use here?"

The assistant should naturally combine voice and vision.

Future Features

Eventually support:

Wake word

Conversation memory

Tool calling

Home Assistant integration

Smart home control

Weather

Navigation

Reminders

Context awareness

Calendar

Email

Slack

GitHub

Software engineering assistance

Object recognition

OCR

Scene understanding

Live translation

Continuous visual awareness (if supported)

Background conversation

Multiple AI providers

Offline local command handling

Technical Requirements

Platform:

Native iOS

Language:

Swift

Frameworks:

SwiftUI

Swift Concurrency

Combine where appropriate

Dependency Injection

Clean Architecture

MVVM

Feature modules

Repository pattern

Provider abstraction

Protocol-oriented programming

AI Layer

Design the AI layer so OpenAI can later be replaced with another provider without affecting application logic.

Use protocol abstractions.

No vendor lock-in.

Audio

Design for:

Streaming input

Streaming output

Echo cancellation

Noise suppression

Bluetooth optimization

Conversation interruption

Barge-in

Low latency

Graceful reconnection

Camera

Research Meta's current SDK capabilities.

Use only officially supported APIs.

Determine:

Live video access

Still image capture

Frame streaming

Image events

Permissions

SDK limitations

Privacy constraints

Design around those limitations.

User Experience

The user should feel like they are talking to an intelligent companion.

Minimal phone interaction.

Phone stays in pocket.

Eventually support launching directly from a voice command or other hands-free mechanism where iOS allows.

Design around Apple's platform restrictions rather than fighting them.

Security

API keys never live in plaintext.

Secure credential storage.

Authentication layer.

Encrypted networking.

Production-ready architecture.

Development Philosophy

Treat this as if we are building a startup product.

Never generate unnecessary boilerplate.

Prioritize elegant architecture over quick hacks.

Whenever recommending a design:

Explain:

Why

Tradeoffs

Future scalability

Potential pitfalls

Alternative approaches

Deliverables

Help me create:

Architecture diagrams

Sequence diagrams

Class diagrams

API design

Repository layout

Milestone roadmap

Development schedule

Technical documentation

Implementation tasks

Testing strategy

Deployment strategy

CI/CD pipeline

Performance benchmarks

Future expansion roadmap
