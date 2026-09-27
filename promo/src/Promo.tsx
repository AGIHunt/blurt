import React from "react";
import { AbsoluteFill, Sequence, staticFile, useCurrentFrame } from "remotion";
import { Audio } from "@remotion/media";
import { FPS, SceneTime, TL, lin } from "./lib";
import { Captions, Grain } from "./ui";
import { Blind, Hook, Pain, Reveal } from "./scenes1";
import { Beyond, CTA, Export, Items, Peak, Record, Review } from "./scenes2";

const SCENES: [keyof typeof TL.scenes, React.FC][] = [
  ["hook", Hook], ["pain", Pain], ["blind", Blind], ["reveal", Reveal], ["record", Record], ["items", Items],
  ["review", Review], ["peak", Peak], ["export", Export], ["beyond", Beyond], ["cta", CTA],
];

/** Every cut lands on the beat; each scene punches in with a short zoom-blur. */
const Enter: React.FC<{ start: number; children: React.ReactNode }> = ({ start, children }) => {
  const t = start + useCurrentFrame() / FPS;
  const p = lin(t, start, start + 0.28);
  return (
    <AbsoluteFill style={{ transform: `scale(${1.06 - 0.06 * p})`, filter: p < 1 ? `blur(${(1 - p) * 10}px)` : undefined, opacity: Math.min(1, 0.3 + p) }}>
      {children}
    </AbsoluteFill>
  );
};

export const Promo: React.FC = () => (
  <AbsoluteFill style={{ background: "#000" }}>
    {SCENES.map(([k, S]) => {
      const [a, b] = TL.scenes[k];
      const from = Math.round(a * FPS);
      return (
        <Sequence key={k} from={from} durationInFrames={Math.round(b * FPS) - from} name={k}>
          <SceneTime start={from / FPS}>
            <Enter start={from / FPS}>
              <S />
            </Enter>
          </SceneTime>
        </Sequence>
      );
    })}
    <SceneTime start={0}>
      <Captions />
      <Grain />
    </SceneTime>
    <Audio src={staticFile("soundtrack.wav")} />
  </AbsoluteFill>
);
