import React from "react";
import { Composition } from "remotion";
import { Promo } from "./Promo";
import { FPS, TL } from "./lib";

export const Root: React.FC = () => (
  <Composition id="Promo" component={Promo} width={1920} height={1080} fps={FPS} durationInFrames={Math.round(TL.duration * FPS)} />
);
