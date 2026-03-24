// Reverb — reads from and replaces the group's private bus
SynthDef(\satoriReverb, { |in=0, wet=0.5, room=0.8, damp=1.0|
    var sig = In.ar(in, 2);
    ReplaceOut.ar(in, FreeVerb2.ar(sig[0], sig[1], wet, room, damp));
}).add;

// Per-stream limiter — sits at the tail of each group's private bus
SynthDef(\satoriLimiter, { |in=0, out=0, level=0.9|
    Out.ar(out, Limiter.ar(In.ar(in, 2), level));
}).add;

// FM Synth
// Params: note (midi), harm, modi, amp, ADSR envelope (a, d, s, r), gate
SynthDef(\fm, { |out=0, n=60, harm=2.0, modi=3.0, amp=0.5,
                 a=0.01, d=0.1, s=0.7, r=0.3, gate=1|
    var freq = n.midicps;
    var mod  = SinOsc.ar(freq * harm, 0, freq * modi);
    var car  = SinOsc.ar(freq + mod);
    var env  = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    Out.ar(out, (car * env * amp * 0.5).dup);
}).add;
