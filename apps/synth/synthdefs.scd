// FM Synth
// Params: note (midi), modRatio, modIndex, amp, ADSR envelope (a, d, s, r), gate
SynthDef(\fm, { |out=0, note=60, modRatio=2.0, modIndex=3.0, amp=0.5,
                 a=0.01, d=0.1, s=0.7, r=0.3, gate=1|
    var freq = note.midicps;
    var mod  = SinOsc.ar(freq * modRatio, 0, freq * modIndex);
    var car  = SinOsc.ar(freq + mod);
    var env  = EnvGen.kr(Env.adsr(a, d, s, r), gate, doneAction: Done.freeSelf);
    Out.ar(out, (car * env * amp).dup);
}).add;
