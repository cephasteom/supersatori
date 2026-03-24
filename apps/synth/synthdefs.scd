// FM Synth
// Params: note (midi), harm, modi, amp, ADSR envelope (a, d, s, r), gate
SynthDef(\fm, { |out=0, n=60, harm=2.0, modi=3.0, amp=0.5,
                 a=0.01, d=0.1, s=0.7, r=0.3, gate=1|
    var freq = n.midicps;
    var mod  = SinOsc.ar(freq * harm, 0, freq * modi);
    var car  = SinOsc.ar(freq + mod);
    var env  = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    Out.ar(out, (car * env * amp).dup);
}).add;
