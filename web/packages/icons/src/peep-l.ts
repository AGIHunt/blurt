/// <reference path="./assets.d.ts" />
/* Peep's large sheets (192 px square: the app window's welcome and empty states, up to 108 px at 2×) — idle, hello
   and done, the clips the Mac shows on its light surfaces. Import once in an app that shows Peep that large. */
import done from "../peep/l-done.webp";
import hello from "../peep/l-hello.webp";
import idle from "../peep/l-idle.webp";
import { registerPeepSheets } from "./mascot";

registerPeepSheets("l", { idle, hello, done });
