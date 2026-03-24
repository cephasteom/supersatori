// Reverb — reads from and replaces the group's private bus
SynthDef(\satoriReverb, { |in=0, wet=0.5, room=0.8, damp=1.0|
    var sig = In.ar(in, 2);
    ReplaceOut.ar(in, FreeVerb2.ar(sig[0], sig[1], wet, room, damp));
}).add;

// Delay — time and decay in ms
SynthDef(\satoriDelay, { |in=0, wet=0.5, time=300, decay=1000|
    var sig     = In.ar(in, 2);
    var delayed = CombC.ar(sig, 2.0, time / 1000, decay / 1000);
    ReplaceOut.ar(in, XFade2.ar(sig, delayed, wet * 2 - 1));
}).add;

// Chorus — rate in Hz, depth in ms
SynthDef(\satoriChorus, { |in=0, wet=0.5, rate=0.5, depth=5|
    var sig    = In.ar(in, 2);
    var lfo    = SinOsc.kr(rate, [0, 0.5pi]) * (depth / 1000) + 0.02;
    var chorus = DelayC.ar(sig, 0.1, lfo);
    ReplaceOut.ar(in, XFade2.ar(sig, chorus, wet * 2 - 1));
}).add;

// Per-stream limiter — sits at the tail of each group's private bus
SynthDef(\satoriLimiter, { |in=0, out=0, level=0.9|
    Out.ar(out, Limiter.ar(In.ar(in, 2), level));
}).add;

// FM Synth
// Params: note (midi), harm, modi, amp, pan, lag (ms), ADSR envelope (a, d, s, r, gate)
SynthDef(\fm, { |out=0, n=60, harm=2.0, modi=3.0, amp=0.5, pan=0.5, lag=0,
                 a=10, d=100, s=0.7, r=300, gate=1|
    var lagSec = lag / 1000;
    var freq   = VarLag.kr(n, lagSec).midicps;
    var modIdx = VarLag.kr(modi, lagSec);
    var ampL   = VarLag.kr(amp, lagSec);
    var panL   = VarLag.kr(pan, lagSec);
    var mod    = SinOsc.ar(freq * harm, 0, freq * modIdx);
    var car    = SinOsc.ar(freq + mod);
    var env    = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    Out.ar(out, Pan2.ar(car * env * ampL * 0.5, panL * 2 - 1));
}).add;
