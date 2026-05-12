// Reverb — reads from and replaces the group's private bus
SynthDef(\satoriReverb, { |in=0, wet=0.5, room=0.8, damp=1.0, lag=10|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    var roomL  = VarLag.kr(room, lagSec);
    var dampL  = VarLag.kr(damp, lagSec);
    var sig    = In.ar(in, 2);
    ReplaceOut.ar(in, FreeVerb2.ar(sig[0], sig[1], wetL, roomL, dampL));
}).add;

// Delay — time and decay in ms
SynthDef(\satoriDelay, { |in=0, wet=0.5, time=300, decay=1000, lag=0|
    var lagSec  = lag / 1000;
    var wetL    = VarLag.kr(wet, lagSec);
    var timeL   = VarLag.kr(time, lagSec);
    var decayL  = VarLag.kr(decay, lagSec);
    var sig     = In.ar(in, 2);
    var delayed = CombC.ar(sig, 2.0, timeL / 1000, decayL / 1000);
    ReplaceOut.ar(in, XFade2.ar(sig, delayed, wetL * 2 - 1));
}).add;

// Chorus — rate in Hz, depth in ms
SynthDef(\satoriChorus, { |in=0, wet=0.5, rate=0.5, depth=5, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    var rateL  = VarLag.kr(rate, lagSec);
    var depthL = VarLag.kr(depth, lagSec);
    var sig    = In.ar(in, 2);
    var lfo    = SinOsc.kr(rateL, [0, 0.5pi]) * (depthL / 1000) + 0.02;
    var chorus = DelayC.ar(sig, 0.1, lfo);
    ReplaceOut.ar(in, XFade2.ar(sig, chorus, wetL * 2 - 1));
}).add;

// Bitcrusher — bits: bit depth (1-16), rate: sample rate as fraction of full rate (0-1)
SynthDef(\satoriBitcrusher, { |in=0, wet=0.5, bits=5, rate=0.5, lag=0|
    var lagSec  = lag / 1000;
    var wetL    = VarLag.kr(wet, lagSec);
    var bitsL   = VarLag.kr(bits, lagSec).round(1).max(1);
    var rateL   = VarLag.kr(rate, lagSec).clip(0.001, 1.0);
    var sig     = In.ar(in, 2);
    var crushed = Latch.ar(sig, Impulse.ar(SampleRate.ir * rateL));
    var step    = 2 ** (1 - bitsL);
    crushed     = (crushed / step).round * step;
    ReplaceOut.ar(in, XFade2.ar(sig, crushed, wetL * 2 - 1));
}).add;

// Overdrive — drive: 0-1, maps exponentially to internal gain 1-50
// Uses tanh for smooth soft clipping; output is normalised so unity gain at any drive level
SynthDef(\satoriOverdrive, { |in=0, wet=0.5, drive=0.5, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    var driveL = VarLag.kr(drive, lagSec).linexp(0, 1, 1, 50);
    var sig    = In.ar(in, 2);
    var driven = tanh(sig * driveL) / tanh(driveL);
    ReplaceOut.ar(in, XFade2.ar(sig, driven, wetL * 2 - 1));
}).add;

// Wavefolder — gain: 0-1, maps exponentially to internal gain 1-8
SynthDef(\satoriFolder, { |in=0, wet=0.5, gain=0.5, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    var gainL  = VarLag.kr(gain, lagSec).linexp(0, 1, 1, 8);
    var sig    = In.ar(in, 2);
    var folded = (sig * gainL).fold2(1);
    ReplaceOut.ar(in, XFade2.ar(sig, folded, wetL * 2 - 1));
}).add;

SynthDef(\satoriTape, { |in=0, wet=0.5, age=0.5, flutter=0.5, lag=10|
    var lagSec, wetL, ageL, flutterL;
    var sig, dry, out;
    var drive;
    var wowRate, wowDepth, wowL, wowR;
    var flutterRate, flutterDepth, flutterModL, flutterModR;
    var lpFreq;
    var dropoutRate, dropout;
    var hissAmp;
    var rumbleAmp;
    var crackleAmp;
    var clickRate;
    var fadeIn, fadeOut, fader;

    lagSec   = lag / 1000;
    wetL     = VarLag.kr(wet,     lagSec);
    ageL     = VarLag.kr(age,     lagSec);
    flutterL = VarLag.kr(flutter, lagSec);

    // Fade in over lag ms on instantiation
    fadeIn = Line.kr(0, 1, lagSec);

    sig = In.ar(in, 2);
    dry = In.ar(in, 2);

    // Fade out over lag ms when input has been silent for 1 second
    fadeOut = EnvGen.kr(
        Env([1, 1, 0], [1, lagSec]),
        gate: DetectSilence.ar(sig[0], time: 1.0),
    );

    fader = fadeIn * fadeOut;

    // --- Saturation ---
    drive = ageL.linexp(0, 1, 1.0, 6.0);
    sig = (sig * drive).tanh * (1 / drive.sqrt);

    // --- Wow & Flutter ---
    wowRate      = LFNoise1.kr(0.3).range(0.5, 2.0);
    wowDepth     = flutterL * 0.003;
    wowL         = SinOsc.kr(wowRate,        0).range(1 - wowDepth, 1 + wowDepth);
    wowR         = SinOsc.kr(wowRate * 1.07, 0.4).range(1 - wowDepth, 1 + wowDepth);
    flutterRate  = LFNoise1.kr(0.1).range(8, 12);
    flutterDepth = flutterL * 0.0015;
    flutterModL  = SinOsc.kr(flutterRate,        0).range(1 - flutterDepth, 1 + flutterDepth);
    flutterModR  = SinOsc.kr(flutterRate * 0.97, 0.2).range(1 - flutterDepth, 1 + flutterDepth);
    sig = sig * [wowL * flutterModL, wowR * flutterModR];

    // --- HF roll-off ---
    lpFreq = ageL.linexp(0, 1, 18000, 6000);
    sig = LPF.ar(sig, lpFreq);

    // --- Dropout ---
    dropoutRate = flutterL.linexp(0, 1, 0.3, 2.0);
    dropout     = LFNoise1.kr(dropoutRate).range(0.85, 1.0).pow(3);
    sig = sig * dropout;

    // --- Hiss ---
    hissAmp = ageL.linexp(0, 1, 0.0001, 0.0008);
    sig = sig + HPF.ar(WhiteNoise.ar([1,1]) * hissAmp, 4000);

    // --- Rumble ---
    rumbleAmp = ageL.linexp(0, 1, 0.00005, 0.003);
    sig = sig + LPF.ar(PinkNoise.ar([1,1]) * rumbleAmp, 300);

    // --- Crackle ---
    crackleAmp = ageL.linexp(0, 1, 0.00005, 0.004);
    sig = sig + (Crackle.ar(1.95, [1,1]) * crackleAmp);

    // --- Clicks ---
    clickRate = ageL.linexp(0, 1, 0.05, 4.0);
    sig = sig + (LFNoise0.kr(clickRate).range(0, 1) * Dust.ar(clickRate * 0.5) * ageL.linexp(0, 1, 0.001, 0.008));

    // --- Non-linear compression to tame peaks from saturation and modulation, and glue the effect together ---
    sig = Compander.ar(sig, sig,
        thresh: 0.5,
        slopeBelow: 1,
        slopeAbove: 0.4,
        clampTime: 0.01,
        relaxTime: 0.1
    );

    // Apply fader only to wet signal, dry always passes through
    out = XFade2.ar(dry, sig * fader, wetL * 2 - 1);
    ReplaceOut.ar(in, out);
}).add;

// Spectral blur — smears magnitude across FFT bins, diffused through a short allpass network
SynthDef(\satoriBlur, { |in=0, wet=0.5, smear=0.5, lag=0|
    var lagSec  = lag / 1000;
    var wetL    = VarLag.kr(wet, lagSec);
    var smearL  = VarLag.kr(smear, lagSec);
    var sig     = In.ar(in, 2);
    var blurred = sig.collect({ |channel|
        var chain = FFT(LocalBuf(2048), channel);
        chain = PV_MagSmear(chain, (smearL * 64).round);
        IFFT(chain);
    });
    // Two-stage allpass diffusion: smooths FFT block edges without adding reverb tail.
    // Asymmetric L/R delay times preserve stereo width.
    blurred = AllpassN.ar(blurred, 0.04, [0.0173, 0.0231], 0.04);
    blurred = AllpassN.ar(blurred, 0.04, [0.0107, 0.0193], 0.04);
    ReplaceOut.ar(in, XFade2.ar(sig, blurred, wetL * 2 - 1));
}).add;

// Feedback sustainer — recirculates signal through a tonefiltered loop; feedback controls sustain length
SynthDef(\satoriFeed, { |in=0, wet=0.5, feedback=0.7, tone=0.7, lag=0|
    var lagSec    = lag / 1000;
    var wetL      = VarLag.kr(wet, lagSec);
    var feedbackL = VarLag.kr(feedback, lagSec).clip(0, 0.99);
    var toneL     = VarLag.kr(tone, lagSec).linexp(0, 1, 20, 20000);
    var sig       = In.ar(in, 2);
    var fb        = LocalIn.ar(2);
    var sustained = sig + fb;
    LocalOut.ar(LPF.ar(sustained, toneL) * feedbackL);
    ReplaceOut.ar(in, XFade2.ar(sig, sustained, wetL * 2 - 1));
}).add;

// Noise gate — threshold and reduce are 0-1; a and r are attack/release in ms
// reduce=1 silences when gate closes, reduce=0.5 attenuates by half; wet=1 fully active
// Noise gate — threshold and reduce are 0-1; a and r are attack/release in ms
// reduce=1 silences when gate closes, reduce=0.5 attenuates by half; wet=1 fully active
// sidechain: bus index to use as detector instead of the gate's own input (-1 = disabled)
SynthDef(\satoriGate, { |in=0, wet=1.0, threshold=0.1, reduce=1.0, a=10, r=100, lag=0, sidechain= -1|
    var lagSec     = lag / 1000;
    var wetL       = VarLag.kr(wet, lagSec);
    var thresholdL = VarLag.kr(threshold, lagSec);
    var reduceL    = VarLag.kr(reduce, lagSec);
    var aSec       = VarLag.kr(a, lagSec) / 1000;
    var rSec       = VarLag.kr(r, lagSec) / 1000;
    var sig        = In.ar(in, 2);
    var scSig      = In.ar(sidechain.max(0), 1);
    var detector   = Select.ar(sidechain >= 0, [sig[0], scSig]);
    var ampKr      = Amplitude.kr(detector, 0.002, 0.002);
    var open       = (ampKr > thresholdL).asFloat;
    var gateGain   = LagUD.kr(open, aSec, rSec);
    var gain       = 1 - (reduceL * (1 - gateGain));
    var gated      = sig * gain;
    ReplaceOut.ar(in, XFade2.ar(sig, gated, wetL * 2 - 1));
}).add;

// Per-stream limiter — sits at the tail of each group's private bus
SynthDef(\satoriLimiter, { |in=0, out=0, level=1.0|
    Out.ar(out, Limiter.ar(In.ar(in, 2) * level));
}).add;

// FX send — reads from a source stream bus and additively writes to an fx stream bus
SynthDef(\satoriSend, { |in=0, out=0, wet=0, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    Out.ar(out, In.ar(in, 2) * wetL);
}).add;

// Sampler — buffers are normalised to stereo at load time (mono files get ch0 duplicated)
// Rate chain: snap (ms, 0=off) sets base rate so buffer lasts snap ms, then scaled by n (midi, 60=1x) and rate
// Negative rate plays backwards. Without snap, just n * rate.
SynthDef(\sampler, { |out=0, buf=0, amp=0.5, pan=0.5, lag=0, n=60, rate=1.0, begin=0, loop=0,
                      snap=0, a=1, d=0, s=1.0, r=50, gate=1,
                      lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var nL        = VarLag.kr(n, lagSec);
    var rateL     = VarLag.kr(rate, lagSec);
    var nScale    = (nL - 60).midiratio;
    var snapRate  = BufDur.kr(buf) * 1000 / snap.max(1e-4);
    var baseRate  = Select.kr(snap > 0, [1, snapRate]);
    var finalRate = baseRate * nScale * rateL * BufRateScale.kr(buf);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var sig       = PlayBuf.ar(2, buf, finalRate,
                      startPos: begin * BufFrames.kr(buf), loop: loop);
    var lpfL  = VarLag.kr(lpf, lagSec);
    var hpfL  = VarLag.kr(hpf, lagSec);
    var bpfL  = VarLag.kr(bpf, lagSec);
    var resL  = VarLag.kr(res, lagSec);
    sig = Balance2.ar(sig[0], sig[1], panL * 2 - 1, ampL * env);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Granular Synth — uses Warp1 which reads stereo buffers directly (no duplicate mono buffers needed)
// begin: start position for the scan (0-1)
// snap: ms to traverse the full buffer (0 = scan at natural buffer rate), rate scales scan speed
// n: pitch within grains (midi, 60 = original pitch), independent of scan speed
// posrand: per-grain position scatter (0-1), overlaps: simultaneous grains
// gdur: grain duration (ms)
SynthDef(\granular, { |out=0, buf=0, amp=1, pan=0.5, lag=0, n=60, rate=1.0,
                       snap=0,
                       begin=0, posrand=0.0,
                       gdur=100, overlaps=8,
                       a=10, d=100, s=1.0, r=300, gate=1,
                       lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec      = lag / 1000;
    var ampL        = VarLag.kr(amp, lagSec);
    var panL        = VarLag.kr(pan, lagSec);
    var nL          = VarLag.kr(n, lagSec);
    var rateL       = VarLag.kr(rate, lagSec);
    var beginL      = VarLag.kr(begin, lagSec);
    var nScale      = (nL - 60).midiratio;
    // snap=0: traverse buffer in BufDur seconds (natural rate); snap>0: traverse in snap ms; both scaled by rate
    var freeRate    = rateL / BufDur.kr(buf) / ControlRate.ir;
    var snapRate    = rateL * 1000 / snap.max(1e-4) / ControlRate.ir;
    var pointerRate = Select.kr(snap > 0, [freeRate, snapRate]);
    var pointer     = Phasor.kr(0, pointerRate, beginL, 1.0, beginL);
    var gdurSec     = gdur / 1000;
    var sig         = Warp1.ar(2, buf, pointer, nScale, gdurSec, -1, overlaps, posrand, 2);
    var env         = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var lpfL  = VarLag.kr(lpf, lagSec);
    var hpfL  = VarLag.kr(hpf, lagSec);
    var bpfL  = VarLag.kr(bpf, lagSec);
    var resL  = VarLag.kr(res, lagSec);
    sig = Balance2.ar(sig[0], sig[1], panL * 2 - 1, ampL * env);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Granular Synth 2 — uses Warp1 which reads stereo buffers directly (no duplicate mono buffers needed)
// begin: start position for the scan (0-1)
// snap: ms to traverse the full buffer (0 = scan at natural buffer rate), rate scales scan speed
// n: pitch within grains (midi, 60 = original pitch), independent of scan speed
// posrand: per-grain position scatter (0-1);
// grainrate: grain trigger rate (Hz); 
// graindur: grain duration as multiple of grain period (1=fills, 2=overlaps)
// graindensity: simultaneous grains
// jitter: random variation in grain position (0-1), as fraction of buffer size — helps avoid metallic artifacts when using snap or low grainrate
SynthDef(\granular2, { |out=0, buf=0, amp=1, pan=0.5, lag=0, n=60, rate=1.0,
                       snap=0,
                       begin=0, posrand=0.0,
                       grainrate=16, graindur=1.0, graindensity=8,
                       a=10, d=100, s=1.0, r=300, gate=1,
                       lpf=0, hpf=0, bpf=0, res=1.0, jitter=0.0003|
    var lagSec      = lag / 1000;
    var ampL        = VarLag.kr(amp, lagSec);
    var panL        = VarLag.kr(pan, lagSec);
    var nL          = VarLag.kr(n, lagSec);
    var rateL       = VarLag.kr(rate, lagSec);
    var beginL      = VarLag.kr(begin, lagSec);
    var grainrateL  = VarLag.kr(grainrate, lagSec);
    var graindurL   = VarLag.kr(graindur, lagSec);
    var graindensityL = VarLag.kr(graindensity, lagSec).round(1).max(1);
    var nScale      = (nL - 60).midiratio;
    // snap=0: traverse buffer in BufDur seconds (natural rate); snap>0: traverse in snap ms; both scaled by rate
    var freeRate    = rateL / BufDur.kr(buf) / ControlRate.ir;
    var snapRate    = rateL * 1000 / snap.max(1e-4) / ControlRate.ir;
    var pointerRate = Select.kr(snap > 0, [freeRate, snapRate]);
    var pointer     = Phasor.kr(0, pointerRate, beginL, 1.0, beginL)
        + LFNoise1.ar(100).bipolar(jitter);
    var gdurSec     = graindurL / grainrateL;
    var sig         = Warp1.ar(2, buf, pointer, nScale, gdurSec, -1, graindensityL, posrand, 2);
    var env         = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var lpfL  = VarLag.kr(lpf, lagSec);
    var hpfL  = VarLag.kr(hpf, lagSec);
    var bpfL  = VarLag.kr(bpf, lagSec);
    var resL  = VarLag.kr(res, lagSec);
    sig = Balance2.ar(sig[0], sig[1], panL * 2 - 1, ampL * env);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Kick Synth
// Three layers: tone (sine + pitch sweep), click (bandpass noise transient), noise (lpf noise tail).
// fstart: initial sweep frequency (Hz); pdec: pitch decay (ms).
// click: beater transient level; noise: noise body level; drive: tanh saturation on tone only.
// Percussive by default (s=0). Each synth creation fires its own Impulse for internal envelopes.
SynthDef(\kick, { |out=0, n=36, amp=0.8, pan=0.5, lag=0,
                   a=2, d=400, s=0.0, r=50, gate=1,
                   fstart=180, pdec=60,
                   click=0.5, noise=0.0, drive=0.0,
                   lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var fstartL   = VarLag.kr(fstart, lagSec);
    var pdecL     = VarLag.kr(pdec, lagSec);
    var clickL    = VarLag.kr(click, lagSec);
    var noiseL    = VarLag.kr(noise, lagSec);
    var driveL    = VarLag.kr(drive, lagSec);
    var atrig     = Impulse.ar(0);                                   // one-shot at synth creation
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    // Tone: sine with exponential pitch sweep from fstart down to freq
    var pitchEnv  = Decay2.ar(atrig, 0.001, pdecL / 1000);
    var sweepFreq = freq + (pitchEnv * (fstartL - freq));
    var driveGain = 1 + driveL * 9;                                  // 1x–10x
    var tone      = tanh(SinOsc.ar(sweepFreq) * driveGain) / tanh(driveGain);
    // Click: bandpass noise, ~8ms decay — the physical beater transient
    var clickSig  = BPF.ar(WhiteNoise.ar, 2500, 0.7) * Decay2.ar(atrig, 0.001, 0.008) * clickL;
    // Noise: lowpass body, decays at half the main envelope time
    var noiseSig  = LPF.ar(WhiteNoise.ar, 250) * Decay2.ar(atrig, 0.001, d / 2000) * noiseL;
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    var sig       = Pan2.ar((tone + clickSig + noiseSig) * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Snare Synth
// Two layers: body (two inharmonic sines with pitch sweep) and snare noise (HPF white noise).
// body: tonal layer level; snap: wire noise level; tight: wire noise decay (ms).
// fstart/pdec: pitch sweep start (Hz) and decay (ms). drive: tanh saturation on body tones.
// Each layer has its own Decay2 envelope so body and wire decay independently.
SynthDef(\snare, { |out=0, n=48, amp=0.8, pan=0.5, lag=0,
                    a=2, d=150, s=0.0, r=30, gate=1,
                    fstart=250, pdec=30,
                    snap=0.8, body=0.7, drive=0.0, tight=120,
                    lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var fstartL   = VarLag.kr(fstart, lagSec);
    var pdecL     = VarLag.kr(pdec, lagSec);
    var snapL     = VarLag.kr(snap, lagSec);
    var bodyL     = VarLag.kr(body, lagSec);
    var driveL    = VarLag.kr(drive, lagSec);
    var tightL    = VarLag.kr(tight, lagSec);
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    var atrig     = Impulse.ar(0);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    // Body: two inharmonic sines (drum head modes) with shared pitch sweep
    var pitchEnv  = Decay2.ar(atrig, 0.001, pdecL / 1000);
    var sweepFreq = freq + (pitchEnv * (fstartL - freq));
    var driveGain = 1 + driveL * 9;
    var tone1     = SinOsc.ar(sweepFreq);
    var tone2     = SinOsc.ar(sweepFreq * 1.6);
    var bodyEnv   = Decay2.ar(atrig, 0.001, d / 1000);
    var bodySig   = tanh((tone1 + (tone2 * 0.6)) * driveGain) / tanh(driveGain) * bodyEnv * bodyL;
    // Snare noise: HPF white noise for wire rattle, independently decaying
    var snareNoise = HPF.ar(WhiteNoise.ar, 1500) * Decay2.ar(atrig, 0.001, tightL / 1000) * snapL;
    var sig       = Pan2.ar((bodySig + snareNoise) * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Sub Synth
// presence: distorts a parallel copy and HPFs out the fundamental from it,
//   so only upper harmonics are added — the sine itself stays pure.
// lfoRate/lfoDepth: amplitude tremolo whose phase resets on each note trigger (starts at full amp).
// sweep: 2-octave pitch sweep on trigger — 1=falls from 2 octaves above, -1=rises from below, 0=off.
// sweepdec: sweep decay time (ms).
SynthDef(\sub, { |out=0, n=60, amp=0.5, pan=0.5, lag=0,
                  a=1, d=0, s=1.0, r=50, gate=1,
                  presence=0.3, lforate=4.0, lfodepth=0.3,
                  sweep=0.0, sweepdec=200,
                  lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var presenceL = VarLag.kr(presence, lagSec);
    var lfoRateL  = VarLag.kr(lforate, lagSec);
    var lfoDepthL = VarLag.kr(lfodepth, lagSec);
    var sweepL    = VarLag.kr(sweep, lagSec);
    var sweepdecL = VarLag.kr(sweepdec, lagSec);
    var trig      = Trig1.kr(gate, 0.001);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    // Pitch sweep: 4^(sweep * decay) — 2 octaves up (sweep=1) or down (sweep=-1)
    var sweepEnv  = Decay2.kr(trig, 0.001, sweepdecL / 1000);
    var pitchFreq = freq * (4 ** (sweepL * sweepEnv));
    // Pure sine sub
    var sub       = SinOsc.ar(pitchFreq);
    // Presence: tanh-distort a copy, HPF to remove the fundamental, mix in at low level
    var distorted = tanh(sub * (presenceL * 8 + 1));
    var harmonics = HPF.ar(distorted, pitchFreq * 1.5) * presenceL;
    var sig       = sub + harmonics;
    // Amp LFO: phase resets to peak on each trigger so note always starts at full amplitude
    var lfoPhase  = Phasor.kr(trig, lfoRateL / ControlRate.ir, 0, 1, 0.25);
    var lfo       = sin(lfoPhase * 2pi);
    var ampMod    = 1 - (lfoDepthL * (1 - (lfo * 0.5 + 0.5)));
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    sig = Pan2.ar(sig * env * ampL * ampMod * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Subtractive Synth
// wave: 0=saw, 1=pulse; pw: pulse width (0-1, only used when wave=1)
// ffreq: base filter cutoff (Hz), fres: resonance (0=none, 1=max), fenv: Hz added to cutoff at envelope peak
// Filter tracks amp envelope shape. Post-process filters (lpf/hpf/bpf/res) work as on other synths.
SynthDef(\subtractive, { |out=0, n=60, wave=0, pw=0.5, amp=0.5, pan=0.5, lag=0,
                          a=10, d=200, s=0.5, r=300, gate=1,
                          ffreq=2000, fres=0.3, fenv=0,
                          lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec  = lag / 1000;
    var nL      = VarLag.kr(n, lagSec);
    var freq    = nL.midicps;
    var ampL    = VarLag.kr(amp, lagSec);
    var panL    = VarLag.kr(pan, lagSec);
    var pwL     = VarLag.kr(pw, lagSec);
    var ffreqL  = VarLag.kr(ffreq, lagSec);
    var fresL   = VarLag.kr(fres, lagSec);
    var fenvL   = VarLag.kr(fenv, lagSec);
    var env     = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var osc     = Select.ar(wave.round(1), [Saw.ar(freq), Pulse.ar(freq, pwL)]);
    var cutoff  = (ffreqL + (fenvL * env)).clip(20, 20000);
    var rq      = 1 - (fresL * 0.99);           // rq=1 no resonance, rq=0.01 max resonance
    var filtered = RLPF.ar(osc, cutoff, rq);
    var lpfL    = VarLag.kr(lpf, lagSec);
    var hpfL    = VarLag.kr(hpf, lagSec);
    var bpfL    = VarLag.kr(bpf, lagSec);
    var resL    = VarLag.kr(res, lagSec);
    var sig     = Pan2.ar(filtered * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Karplus-Strong plucked string
// Exciter is a noise burst triggered once at synth creation; pitch set by delay line (1/freq).
// decay: ring time (ms); coef: loop filter coefficient (0=bright, 1=dull/mellow)
// No d/s params — the physical decay is the envelope. Gate/release allow early cutoff.
SynthDef(\karplus, { |out=0, n=60, amp=0.5, pan=0.5, lag=0,
                      decay=1000, coef=0.5,
                      a=1, r=50, gate=1,
                      lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec  = lag / 1000;
    var nL      = VarLag.kr(n, lagSec);
    var freq    = nL.midicps;
    var ampL    = VarLag.kr(amp, lagSec);
    var panL    = VarLag.kr(pan, lagSec);
    var decayL  = VarLag.kr(decay, lagSec);
    var coefL   = VarLag.kr(coef, lagSec);
    var env     = EnvGen.kr(Env.asr(a / 1000, 1.0, r / 1000), gate, doneAction: Done.freeSelf);
    var exciter = WhiteNoise.ar(1);
    var plucked = Pluck.ar(exciter, Impulse.kr(0), 0.05, freq.reciprocal, decayL / 1000, coefL);
    var lpfL    = VarLag.kr(lpf, lagSec);
    var hpfL    = VarLag.kr(hpf, lagSec);
    var bpfL    = VarLag.kr(bpf, lagSec);
    var resL    = VarLag.kr(res, lagSec);
    var sig     = Pan2.ar(plucked * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Pad — 7 detuned saws spread symmetrically across the stereo field (supersaw style)
// detune: total spread in cents across all voices; drift: per-voice slow random Hz offset
// Slow attack default (a=500). No d/s defaults encourage open sustain.
SynthDef(\pad, { |out=0, n=60, amp=0.5, pan=0.5, lag=0,
                  detune=30, drift=0.5,
                  a=500, d=0, s=1.0, r=800, gate=1,
                  lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var detuneL   = VarLag.kr(detune, lagSec);
    var driftL    = VarLag.kr(drift, lagSec);
    var numVoices = 7;
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var voices    = numVoices.collect { |i|
        var pos         = i / (numVoices - 1) * 2 - 1;           // -1 to 1
        var detuneCents = pos * (detuneL / 2);                    // ±detune/2 cents each side
        var driftHz     = LFNoise1.kr(rrand(0.1, 0.5)) * driftL; // independent per-voice, rate fixed at build time
        var voiceFreq   = freq * (detuneCents / 100).midiratio + driftHz;
        Pan2.ar(Saw.ar(voiceFreq), pos)
    };
    var sig       = Mix(voices) / numVoices;
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res.clip(0.01, 1), lagSec);
    sig = Balance2.ar(sig[0], sig[1], panL * 2 - 1, ampL * env * 0.5);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Acid (TB-303 style)
// wave: 0=saw, 1=square. Filter auto-sweeps on every gate: opens to ffreq+fenv*(1+accent), decays over fdec ms.
// fenv: sweep amount in Hz — set to 0 for a static filter; accent: 0-1 boosts sweep and amp.
// Slide: use lag (ms) on n for portamento. Uses MoogFF ladder filter for authentic resonance.
SynthDef(\acid, { |out=0, n=60, wave=0, amp=0.5, pan=0.5, lag=0,
                   a=1, d=0, s=1.0, r=50, gate=1,
                   ffreq=300, fres=0.7, fenv=3000, fdec=300,
                   accent=0,
                   lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var ffreqL    = VarLag.kr(ffreq, lagSec);
    var fresL     = VarLag.kr(fres, lagSec);
    var fenvL     = VarLag.kr(fenv, lagSec);
    var fdecL     = VarLag.kr(fdec, lagSec);
    var accentL   = VarLag.kr(accent, lagSec);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var trig      = Trig1.kr(gate, 0.001);
    var filterEnv = Decay2.kr(trig, 0.001, fdecL / 1000);       // 0→1→0, decays over fdec ms
    var osc       = Select.ar(wave.round(1), [Saw.ar(freq), Pulse.ar(freq, 0.5)]);
    var cutoff    = (ffreqL + (fenvL * (1 + accentL) * filterEnv)).clip(20, 20000);
    var filtered  = MoogFF.ar(osc, cutoff, fresL * 4);           // gain 0-4; 4 = self-oscillation
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    var sig       = Pan2.ar(filtered * env * ampL * (1 + accentL) * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Additive Lazer
// 8 sine partials at harmonic ratios. Pitch sweeps exponentially from freq*psweep down to freq over pdec ms.
// psweep: multiplier at note start (2.0=octave above, 1.0=no sweep); pdec: sweep decay (ms)
// rolloff: amplitude weight per partial as rolloff^i — 0.0=only fundamental, 1.0=all partials equal
// Percussive by default (s=0); sustain-capable if s raised. CPU cost: ~8 SinOscs, minimal.
SynthDef(\lazer, { |out=0, n=60, amp=0.5, pan=0.5, lag=0,
                        a=1, d=300, s=0.0, r=80, gate=1,
                        psweep=2.0, pdec=80,
                        rolloff=0.6,
                        lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var psweepL   = VarLag.kr(psweep, lagSec);
    var pdecL     = VarLag.kr(pdec, lagSec);
    var rolloffL  = VarLag.kr(rolloff, lagSec);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var trig      = Trig1.kr(gate, 0.001);
    var pitchEnv  = Decay2.kr(trig, 0.001, pdecL / 1000);
    var sweepFreq = freq * (psweepL ** pitchEnv);    // exponential: psweep at attack, 1x at rest
    var sig       = Mix.fill(8, { |i|
        SinOsc.ar(sweepFreq * (i + 1)) * (rolloffL ** i)
    }) / 8;                                          // /8 normalises for rolloff=1 (all equal)
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    sig = Pan2.ar(sig * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// FM Synth
// Params: note (midi), harm, modi, amp, pan, lag (ms), ADSR envelope (a, d, s, r, gate)
// Modulator envelope (moda, modd, mods, modr) scales the mod index over time
// Keyscaling: both mod index and amp scale by 2^(-0.5) per octave above middle C
SynthDef(\fm, { |out=0, n=60, harm=2.0, modi=3.0, amp=0.5, pan=0.5, lag=0,
                 a=10, d=100, s=0.7, r=300, curve=(-4),
                 gate=1,
                 moda=0, modd=100, mods=1.0, modr=500, modcurve=(-4),
                 lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec   = lag / 1000;
    var nL       = VarLag.kr(n, lagSec);
    var freq     = nL.midicps;
    var ks       = (nL - 60) / 12;            // octaves above/below middle C
    var ampL     = VarLag.kr(amp, lagSec) * (2 ** (ks * -0.5));
    var modIdx   = VarLag.kr(modi, lagSec) * (2 ** (ks * -0.5)) * ampL;
    var panL     = VarLag.kr(pan, lagSec);
    var modEnv   = EnvGen.kr(Env.adsr(moda / 1000, modd / 1000, mods, modr / 1000, curve: modcurve), gate);
    var mod      = SinOsc.ar(freq * harm, 0, freq * modIdx * modEnv);
    var car      = SinOsc.ar(freq + mod);
    var env      = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000, curve: curve), gate, doneAction: Done.freeSelf);
    var lpfL  = VarLag.kr(lpf, lagSec);
    var hpfL  = VarLag.kr(hpf, lagSec);
    var bpfL  = VarLag.kr(bpf, lagSec);
    var resL  = VarLag.kr(res, lagSec);
    var sig   = Pan2.ar(car * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
    Out.ar(out, sig);
}).add;

// Bandpass filter saw - adapted from Eli Fieldsteel's SynthDef in SuperCollider Tutorial 16
// See https://www.youtube.com/watch?v=oR4VZy2LJ60&list=PLPYzvS8A_rTaNDweXe6PX4CXSGq4iEWYC&index=17
// use n for MIDI note input or freq for direct frequency; 
// detune is slow random vibrato in cents; 
// cfhzmin/max and cfmin/max/rqmin/max are ranges for the random filter modulation
SynthDef(\bpfsaw, {
    |out=0, n=60.0, freq=0.0,
     amp=0.5, pan=0.5, lag=0,
     detune=0.2,
     cfhzmin=0.1, cfhzmax=0.3,
     cfmin=500, cfmax=2000, rqmin=0.1, rqmax=0.2,
     a=10, d=100, s=0.7, r=300, curve=(-4),
     gate=1,
     lpf=0, hpf=0, bpf=0, res=1.0|

    var lagSec   = (lag / 1000).max(0);
    var f        = VarLag.kr(Select.kr(freq > 0, [n.midicps, freq]), lagSec);
    var ampL     = VarLag.kr(amp.clip(0.0, inf), lagSec);
    var panL     = VarLag.kr(pan.clip(0, 1), lagSec);

    // Lagged filter params
    var lpfL     = VarLag.kr(lpf.clip(0, 1), lagSec);
    var hpfL     = VarLag.kr(hpf.clip(0, 1), lagSec);
    var bpfL     = VarLag.kr(bpf.clip(0, 1), lagSec);
    var resL     = VarLag.kr(res.clip(0.01, 1), lagSec);

    // Safe exprange bounds — must be strictly positive, lo < hi
    var safeCfmin   = VarLag.kr(cfmin.max(20), lagSec);
    var safeCfmax   = VarLag.kr(cfmax.max(safeCfmin + 1).min(20000), lagSec);
    var safeRqmin   = VarLag.kr(rqmin.max(0.01), lagSec);
    var safeRqmax   = VarLag.kr(rqmax.max(safeRqmin + 0.001).min(2.0), lagSec);
    var safeCfhzmin = VarLag.kr(cfhzmin.max(0.01), lagSec);
    var safeCfhzmax = VarLag.kr(cfhzmax.max(safeCfhzmin + 0.001).min(100), lagSec);

    var env = EnvGen.kr(
        Env.adsr(
            (a / 1000).max(0.001),
            (d / 1000).max(0.001),
            s.clip(0, 1),
            (r / 1000).max(0.001),
            curve: curve
        ),
        gate, doneAction: Done.freeSelf
    );

    var sig = Saw.ar(f * {LFNoise1.kr(0.5, detune).midiratio}!2);

    sig = BPF.ar(
        sig,
        {LFNoise1.kr(
            LFNoise1.kr(4).exprange(safeCfhzmin, safeCfhzmax)
        ).exprange(safeCfmin, safeCfmax)}!2,
        {LFNoise1.kr(0.5).exprange(safeRqmin, safeRqmax)}!2
    );

    sig = Balance2.ar(sig[0], sig[1], panL * 2 - 1) * env * ampL;

    // Select-based filters — only active when param > 0
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 200).max(20))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000).min(20000))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL.linexp(0.01, 1, 2.0, 0.01))]);

    Out.ar(out, sig);
}).add;

// Template for new synths — copy and paste, then fill in the ... with the core signal generation. 
// SynthDef(\template, {
//     |out=0, n=60, amp=0.5, pan=0.5, lag=0,
//      a=10, d=100, s=0.7, r=300, curve=(-4),
//      gate=1,
//      lpf=0, hpf=0, bpf=0, res=1.0|
//     var lagSec   = lag / 1000;
//     var nL       = VarLag.kr(n, lagSec);
//     var freq     = nL.midicps;
//     var ampL     = VarLag.kr(amp, lagSec);
//     var panL     = VarLag.kr(pan, lagSec);
//     var env      = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf, curve: curve);
//     var sig = ...
//     sig = Pan2.ar(sig * ampL * 0.5, panL * 2 - 1);
//     sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.linexp(0, 1, 20000, 20))]);
//     sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.linexp(0, 1, 20, 20000))]);
//     sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.linexp(0, 1, 20, 20000), resL)]);
//     Out.ar(out, sig);
// }).add;
