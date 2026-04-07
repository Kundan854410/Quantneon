# Quantneon Frontend — 3D Metaverse Portal

A futuristic Next.js (App Router) + React Three Fiber landing page for **Quantneon**, the Gamified Social AR/VR Hub of the Quant Ecosystem.

## Features

| Feature | Implementation |
|---|---|
| 3D Metaverse Portal | React Three Fiber full-screen WebGL scene |
| Neon City Scene | Procedural city spires, floating orbs, neon grid floor |
| Avatar Hologram | Glowing wireframe + solid icosahedron "Digital Twin" |
| Immersive Controls | OrbitControls (drag to orbit, scroll to zoom, right-drag to pan) |
| Enter Chill Room Portal | Interactive 3D MeshTransmissionMaterial portal with hover effects |
| Post-Processing | Bloom + ChromaticAberration via @react-three/postprocessing |
| 2D HUD Overlay | Tailwind CSS overlay with live clock, controls hint, ecosystem links |
| Cyberpunk Aesthetic | Deep-space bg, neon cyan #00f5ff, magenta #ff00ff, purple #8b00ff |

## Tech Stack

- **Next.js 16** (App Router, "use client" for R3F)
- **React Three Fiber** (@react-three/fiber)
- **Drei helpers** (@react-three/drei) — OrbitControls, Float, Text, Grid, MeshTransmissionMaterial
- **Post-processing** (@react-three/postprocessing) — Bloom, ChromaticAberration
- **Three.js** + TypeScript
- **Tailwind CSS v4**

## Getting Started

```bash
cd quantneon-frontend
npm install
npm run dev        # http://localhost:3000
npm run build      # production build
```

## Scene Controls

| Input | Action |
|---|---|
| Left-drag | Orbit camera |
| Scroll wheel | Zoom in / out |
| Right-drag | Pan camera |
| Click portal | Toggle "Enter Chill Room" overlay |
| 2D button | "ENTER CHILL ROOM" (bottom-center) |

## Quant Ecosystem Integration

The portal simulates connections to:
- **Quantchat** — real-time chat in the Chill Room
- **Quantchill** — ambient audio / relaxation hub
- **Quantmail** — master identity for the Digital Twin hologram
