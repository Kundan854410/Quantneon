"use client";

import { useRef, useState, Suspense } from "react";
import { Canvas, useFrame } from "@react-three/fiber";
import {
  OrbitControls,
  Grid,
  Float,
  Text,
  MeshTransmissionMaterial,
} from "@react-three/drei";
import { EffectComposer, Bloom, ChromaticAberration } from "@react-three/postprocessing";
import { BlendFunction } from "postprocessing";
import { ACESFilmicToneMapping, Vector2 } from "three";
import type { Mesh } from "three";

// ── Avatar Hologram: glowing wireframe icosahedron ──────────────────────────
function AvatarHologram() {
  const meshRef = useRef<Mesh>(null);
  const innerRef = useRef<Mesh>(null);

  useFrame(({ clock }) => {
    const t = clock.getElapsedTime();
    if (meshRef.current) {
      meshRef.current.rotation.y = t * 0.4;
      meshRef.current.rotation.x = Math.sin(t * 0.3) * 0.2;
      meshRef.current.position.y = 1.5 + Math.sin(t * 0.8) * 0.15;
    }
    if (innerRef.current) {
      innerRef.current.rotation.y = -t * 0.6;
      innerRef.current.scale.setScalar(0.85 + Math.sin(t * 1.2) * 0.05);
    }
  });

  return (
    <group position={[0, 1.5, 0]}>
      {/* Outer wireframe shell */}
      <mesh ref={meshRef}>
        <icosahedronGeometry args={[0.9, 1]} />
        <meshBasicMaterial color="#00f5ff" wireframe />
      </mesh>
      {/* Inner glowing solid */}
      <mesh ref={innerRef}>
        <icosahedronGeometry args={[0.55, 1]} />
        <meshStandardMaterial
          color="#00f5ff"
          emissive="#00f5ff"
          emissiveIntensity={3}
          transparent
          opacity={0.25}
        />
      </mesh>
      {/* Vertical scan line effect */}
      <mesh rotation={[Math.PI / 2, 0, 0]} position={[0, 0, 0]}>
        <torusGeometry args={[0.92, 0.008, 8, 60]} />
        <meshBasicMaterial color="#ff00ff" />
      </mesh>
      {/* Label */}
      <Text
        position={[0, -1.3, 0]}
        fontSize={0.13}
        color="#00f5ff"
        anchorX="center"
        anchorY="middle"
      >
        DIGITAL TWIN — QUANTMAIL ID
      </Text>
    </group>
  );
}

// ── Floating neon orbs ───────────────────────────────────────────────────────
function NeonOrb({
  position,
  color,
  delay = 0,
}: {
  position: [number, number, number];
  color: string;
  delay?: number;
}) {
  const ref = useRef<Mesh>(null);
  useFrame(({ clock }) => {
    const t = clock.getElapsedTime() + delay;
    if (ref.current) {
      ref.current.position.y = position[1] + Math.sin(t * 0.7) * 0.3;
      ref.current.rotation.y = t * 0.5;
    }
  });
  return (
    <mesh ref={ref} position={position}>
      <sphereGeometry args={[0.12, 16, 16]} />
      <meshStandardMaterial
        color={color}
        emissive={color}
        emissiveIntensity={6}
        roughness={0}
        metalness={0.5}
      />
    </mesh>
  );
}

// ── Neon City building spires ────────────────────────────────────────────────
function CitySpire({
  position,
  height,
  color,
}: {
  position: [number, number, number];
  height: number;
  color: string;
}) {
  return (
    <group position={position}>
      <mesh position={[0, height / 2, 0]}>
        <boxGeometry args={[0.4, height, 0.4]} />
        <meshStandardMaterial
          color="#050018"
          emissive={color}
          emissiveIntensity={0.4}
          roughness={0.8}
        />
      </mesh>
      {/* Window grids */}
      <mesh position={[0, height / 2, 0]}>
        <boxGeometry args={[0.42, height, 0.42]} />
        <meshBasicMaterial color={color} wireframe transparent opacity={0.15} />
      </mesh>
      {/* Rooftop light */}
      <mesh position={[0, height + 0.12, 0]}>
        <sphereGeometry args={[0.07, 8, 8]} />
        <meshBasicMaterial color={color} />
      </mesh>
    </group>
  );
}

// ── "Enter Chill Room" portal ────────────────────────────────────────────────
function ChillRoomPortal({ onEnter }: { onEnter: () => void }) {
  const ringRef = useRef<Mesh>(null);
  const innerRef = useRef<Mesh>(null);
  const [hovered, setHovered] = useState(false);

  useFrame(({ clock }) => {
    const t = clock.getElapsedTime();
    if (ringRef.current) {
      ringRef.current.rotation.z = t * 0.5;
    }
    if (innerRef.current) {
      const s = hovered ? 1.08 + Math.sin(t * 4) * 0.04 : 1 + Math.sin(t * 2) * 0.02;
      innerRef.current.scale.setScalar(s);
    }
  });

  return (
    <group position={[5, 1.2, -3]}>
      {/* Outer spinning ring */}
      <mesh ref={ringRef}>
        <torusGeometry args={[1.1, 0.06, 16, 80]} />
        <meshBasicMaterial color={hovered ? "#ffffff" : "#ff00ff"} />
      </mesh>
      {/* Second ring counter-rotate */}
      <mesh rotation={[Math.PI / 4, 0, 0]}>
        <torusGeometry args={[1.1, 0.03, 8, 60]} />
        <meshBasicMaterial color="#00f5ff" transparent opacity={0.7} />
      </mesh>
      {/* Clickable portal disc */}
      <mesh
        ref={innerRef}
        onClick={onEnter}
        onPointerOver={() => setHovered(true)}
        onPointerOut={() => setHovered(false)}
      >
        <circleGeometry args={[1.0, 64]} />
        <MeshTransmissionMaterial
          backside
          samples={4}
          resolution={256}
          transmission={1}
          roughness={0.05}
          thickness={0.5}
          ior={1.5}
          chromaticAberration={hovered ? 0.15 : 0.06}
          distortion={hovered ? 0.4 : 0.2}
          distortionScale={0.4}
          temporalDistortion={0.2}
          color={hovered ? "#cc88ff" : "#6600cc"}
        />
      </mesh>
      {/* Label */}
      <Text
        position={[0, -1.4, 0]}
        fontSize={0.16}
        color={hovered ? "#ffffff" : "#ff00ff"}
        anchorX="center"
        anchorY="middle"
      >
        ▶  ENTER CHILL ROOM
      </Text>
      <Text
        position={[0, -1.65, 0]}
        fontSize={0.1}
        color="#8844cc"
        anchorX="center"
        anchorY="middle"
      >
        QUANTCHILL · QUANTCHAT
      </Text>
    </group>
  );
}

// ── Ground grid plane ────────────────────────────────────────────────────────
function NeonGrid() {
  return (
    <>
      <Grid
        position={[0, 0, 0]}
        args={[40, 40]}
        cellSize={1}
        cellThickness={0.5}
        cellColor="#1a0050"
        sectionSize={5}
        sectionThickness={1}
        sectionColor="#3300aa"
        fadeDistance={30}
        fadeStrength={1.5}
        infiniteGrid
      />
    </>
  );
}

// ── Main scene ───────────────────────────────────────────────────────────────
function Scene({ onEnterRoom }: { onEnterRoom: () => void }) {
  return (
    <>
      {/* Ambient & directional light */}
      <ambientLight intensity={0.1} color="#110033" />
      <directionalLight position={[5, 8, 5]} intensity={0.3} color="#00f5ff" />
      <pointLight position={[0, 4, 0]} intensity={8} color="#8b00ff" distance={12} />
      <pointLight position={[5, 3, -3]} intensity={6} color="#ff00ff" distance={10} />
      <pointLight position={[-5, 3, 2]} intensity={5} color="#00f5ff" distance={10} />

      {/* Ground grid */}
      <NeonGrid />

      {/* Avatar hologram */}
      <Float speed={1.5} rotationIntensity={0.2} floatIntensity={0.4}>
        <AvatarHologram />
      </Float>

      {/* Enter Chill Room portal */}
      <ChillRoomPortal onEnter={onEnterRoom} />

      {/* City spires */}
      <CitySpire position={[-6, 0, -5]} height={4.5} color="#00f5ff" />
      <CitySpire position={[-4, 0, -8]} height={6.5} color="#ff00ff" />
      <CitySpire position={[3, 0, -7]} height={5.2} color="#8b00ff" />
      <CitySpire position={[7, 0, -4]} height={3.8} color="#00f5ff" />
      <CitySpire position={[-8, 0, -2]} height={5.8} color="#ff00ff" />
      <CitySpire position={[9, 0, -6]} height={4.2} color="#8b00ff" />
      <CitySpire position={[-3, 0, -12]} height={7.5} color="#00f5ff" />
      <CitySpire position={[1, 0, -10]} height={8} color="#ff00ff" />

      {/* Floating neon orbs */}
      <NeonOrb position={[-3, 2, -2]} color="#00f5ff" delay={0} />
      <NeonOrb position={[3, 2.5, 1]} color="#ff00ff" delay={1.5} />
      <NeonOrb position={[-2, 3, -4]} color="#8b00ff" delay={3} />
      <NeonOrb position={[6, 2, -1]} color="#00f5ff" delay={2} />
      <NeonOrb position={[-5, 2.2, -3]} color="#ff00ff" delay={0.8} />

      {/* Orbit controls */}
      <OrbitControls
        enablePan
        enableZoom
        enableRotate
        maxPolarAngle={Math.PI / 2 - 0.05}
        minDistance={2}
        maxDistance={25}
        target={[0, 1, 0]}
      />

      {/* Post-processing */}
      <EffectComposer>
        <Bloom
          intensity={1.8}
          luminanceThreshold={0.2}
          luminanceSmoothing={0.9}
          mipmapBlur
        />
        <ChromaticAberration
          blendFunction={BlendFunction.NORMAL}
          offset={new Vector2(0.002, 0.002)}
          radialModulation={false}
          modulationOffset={0.5}
        />
      </EffectComposer>
    </>
  );
}

// ── Loading fallback ─────────────────────────────────────────────────────────
function SceneLoader() {
  return (
    <div className="flex items-center justify-center w-full h-full bg-[#020010]">
      <div className="text-center">
        <div className="text-[#00f5ff] text-xl tracking-widest mb-3 neon-text">
          INITIALIZING NEON CITY
        </div>
        <div className="w-64 h-1 bg-[#0a003a] rounded overflow-hidden mx-auto">
          <div className="h-full bg-[#00f5ff] animate-pulse w-3/4 rounded" />
        </div>
      </div>
    </div>
  );
}

// ── Public component ─────────────────────────────────────────────────────────
export default function NeonScene({ onEnterRoom }: { onEnterRoom: () => void }) {
  return (
    <div className="w-full h-full">
      <Suspense fallback={<SceneLoader />}>
        <Canvas
          camera={{ position: [0, 3, 10], fov: 60 }}
          gl={{ antialias: true, toneMapping: ACESFilmicToneMapping }}
          shadows={false}
          dpr={[1, 2]}
        >
          <color attach="background" args={["#020010"]} />
          <fog attach="fog" args={["#020010", 12, 35]} />
          <Scene onEnterRoom={onEnterRoom} />
        </Canvas>
      </Suspense>
    </div>
  );
}
