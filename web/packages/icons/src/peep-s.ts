/// <reference path="./assets.d.ts" />
/* Peep's small sheets (the island's ears — its launch hello too —, toasts, the voice note's head: ≤ 32 px CSS): a 64 px square for 1.5× and 2×
   screens, a 32 px one for 1× and 1.25× (the ticker picks by device pixels). Import once in an app that shows Peep
   that small; the bundler ships only the sheets an app imports. */
import xsDone from "../peep/xs-done.webp";
import xsError from "../peep/xs-error.webp";
import xsHello from "../peep/xs-hello.webp";
import xsIdle from "../peep/xs-idle.webp";
import xsListening from "../peep/xs-listening.webp";
import xsTalking from "../peep/xs-talking.webp";
import xsThinking from "../peep/xs-thinking.webp";
import done from "../peep/s-done.webp";
import error from "../peep/s-error.webp";
import hello from "../peep/s-hello.webp";
import idle from "../peep/s-idle.webp";
import listening from "../peep/s-listening.webp";
import talking from "../peep/s-talking.webp";
import thinking from "../peep/s-thinking.webp";
import { registerPeepSheets } from "./mascot";

registerPeepSheets("xs", { idle: xsIdle, hello: xsHello, listening: xsListening, talking: xsTalking, thinking: xsThinking, done: xsDone, error: xsError });
registerPeepSheets("s", { idle, hello, listening, talking, thinking, done, error });
