// Motion: the damped springs of the macOS island and cards (Capture/Island/Motion.swift).

export class Spring {
  value: number;
  target: number;
  velocity = 0;
  k: number;
  c: number;

  constructor(v: number, response = 0.42, damping = 0.82) {
    this.value = v;
    this.target = v;
    const w = (2 * Math.PI) / response;
    this.k = w * w;
    this.c = 2 * damping * w;
  }

  step(dt: number): number {
    let t = Math.min(dt, 0.05);
    while (t > 0) {
      const h = Math.min(t, 1 / 240);
      const a = -this.k * (this.value - this.target) - this.c * this.velocity;
      this.velocity += a * h;
      this.value += this.velocity * h;
      t -= h;
    }
    return this.value;
  }

  get resting() {
    return Math.abs(this.value - this.target) < 0.01 && Math.abs(this.velocity) < 0.01;
  }

  snap() {
    this.value = this.target;
    this.velocity = 0;
  }
}

/** A card swinging from its clip: θ'' = −k·θ − c·θ' (k = 46, c = 2.6). */
export class Pendulum {
  angle = 0;
  velocity = 0;
  constructor(
    public k = 46,
    public c = 2.6,
  ) {}

  kick(dv: number) {
    this.velocity += dv;
  }

  step(dt: number, hold = false): number {
    let t = Math.min(dt, 0.05);
    const c = hold ? this.c * 6 : this.c; // hovering stops the swing
    while (t > 0) {
      const h = Math.min(t, 1 / 240);
      this.velocity += (-this.k * this.angle - c * this.velocity) * h;
      this.angle += this.velocity * h;
      t -= h;
    }
    return this.angle;
  }

  get resting() {
    return Math.abs(this.angle) < 0.0005 && Math.abs(this.velocity) < 0.0005;
  }
}
