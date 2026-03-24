s.waitForBoot {
    var customPath = thisProcess.nowExecutingPath.dirname +/+ "custom-synthdefs.scd";

    // load core synthdefs
    load(thisProcess.nowExecutingPath.dirname +/+ "synthdefs.scd");

    // load user-defined SynthDefs if present
    if(File.exists(customPath)) { load(customPath) };

    // Parse OSC args into a dictionary, e.g. ["/satori/s0/event", "inst", "fm", "n", 60] -> {inst: "fm", n: 60}
    ~parseParams = { |args|
        var dict = Dictionary.new;
        args.clump(2).do { |pair| dict[pair[0].asSymbol] = pair[1] };
        dict
    };

    // each stream gets its own group, private bus, and voice dictionary
    ~groups     = Dictionary.new;
    ~buses      = Dictionary.new; // stream -> private audio Bus
    ~limiters   = Dictionary.new; // stream -> limiter Synth (anchor for effect insertion)
    ~effects    = Dictionary.new; // stream -> Dictionary(effectName -> Synth)
    ~voices     = Dictionary.new; // stream -> Dictionary(note -> synth)
    ~voiceOrder = Dictionary.new; // stream -> List of notes (oldest first)

    // Known effects: key = param name, value = SynthDef name
    ~knownEffects = Dictionary.newFrom([
        \reverb, \satoriReverb,
        \delay,  \satoriDelay,
        \chorus, \satoriChorus
    ]);

    ~getGroup = { |stream|
        ~groups[stream] ?? {
            var bus     = Bus.audio(s, 2);
            var group   = Group.new(s);
            var limiter = Synth.new(\satoriLimiter, [\in, bus.index, \out, 0], group, \addToTail);
            ~buses[stream]   = bus;
            ~limiters[stream] = limiter;
            ~groups[stream]  = group;
            ~effects[stream] = Dictionary.new;
            "Satori: created group for stream %".format(stream).postln;
            group
        }
    };

    // Extract params for an effect by stripping its name prefix
    // e.g. (reverb, {reverb: 0.5, reverbroom: 0.8}) -> [\wet, 0.5, \size, 0.8]
    // Extract SynthDef args for an effect from params, stripping the effect name prefix
    // e.g. effectName=reverb, params={reverb:0.5, reverbroom:0.8} -> [\wet, 0.5, \size, 0.8]
    ~effectParams = { |effectName, params|
        var prefix = effectName.asString;
        var pairs  = [];
        params.keysValuesDo { |key, val|
            var k = key.asString;
            if(k == prefix) {
                pairs = pairs ++ [\wet, val];
            } {
                if(k.beginsWith(prefix)) {
                    pairs = pairs ++ [k.copyToEnd(prefix.size).asSymbol, val];
                }
            }
        };
        pairs
    };

    ~applyEffects = { |stream, params|
        var streamEffects = ~effects[stream];
        ~knownEffects.keysValuesDo { |effectName, synthDefName|
            var wet = params[effectName];
            if(wet.notNil) {
                var pairs = [\in, ~buses[stream].index] ++ ~effectParams.(effectName, params);
                if(streamEffects[effectName].isNil) {
                    streamEffects[effectName] = Synth.new(
                        synthDefName, pairs, ~limiters[stream], \addBefore
                    );
                } {
                    streamEffects[effectName].set(*pairs);
                }
            }
        }
    };

    ~getVoices = { |stream|
        ~voices[stream] ?? {
            ~voices[stream]     = Dictionary.new;
            ~voiceOrder[stream] = List.new;
            ~voices[stream]
        }
    };

    // Normalise cut value to an array of stream name strings
    // Accepts: 0, "s0", "0,1", "s0,s1", "all"
    ~resolveStreams = { |cut|
        if(cut.asString == "all") {
            ~voices.keys.asArray
        } {
            cut.asString.split($,).collect { |item|
                var t = item.asString.stripWhiteSpace;
                if(t.every { |c| c.isDecDigit }) { "s" ++ t } { t }
            }
        }
    };

    ~cutStreams = { |cut, cutr = 5|
        ~resolveStreams.(cut).do { |stream|
            ~voices[stream].do { |synth| synth.set(\r, cutr, \gate, 0) };
            ~voices[stream]     = Dictionary.new;
            ~voiceOrder[stream] = List.new;
        };
    };

    ~releaseVoice = { |stream, note|
        var v = ~voices[stream];
        if(v.notNil && v[note].notNil) {
            v[note].set(\gate, 0);
            v.removeAt(note);
            ~voiceOrder[stream].remove(note);
        };
    };

    // Route all /satori/* messages
    ~satoriHandler = { |msg, time, replyAddr, recvPort|
        var path = msg[0].asString;

        if(path.beginsWith("/satori/")) {
            var parts  = path.split($/).reject { |s| s.isEmpty };
            var stream = parts[1]; // e.g. "s0"
            var type   = parts[2]; // "event" or "mutation"
            var params = ~parseParams.(msg[1..]);
            var group  = ~getGroup.(stream);

            if(type == "mutation") {
                var pairs = params.getPairs;
                pairs.postln;
                ~voices[stream].do { |synth| synth.set(*pairs) };
                ~applyEffects.(stream, params);
            };

            if(type == "event") {
                var inst = params[\inst];

                if(params[\cut].notNil) { ~cutStreams.(params[\cut], params[\cutr] ?? 5) };
                ~applyEffects.(stream, params);

                if(inst.notNil && SynthDescLib.global.at(inst.asSymbol).notNil) {
                    var dur    = (params[\dur] ?? 250) / 1000;
                    var note   = params[\n] ?? 60;
                    var voices = ~getVoices.(stream);
                    var order  = ~voiceOrder[stream];
                    var synth;

                    ~releaseVoice.(stream, note);
                    if(voices.size >= 8) { ~releaseVoice.(stream, order.first) };

                    synth = Synth(inst.asSymbol, params.getPairs ++ [\out, ~buses[stream].index], group, \addToHead);
                    voices[note] = synth;
                    order.add(note);

                    SystemClock.sched(dur, {
                        if(voices[note] === synth) { ~releaseVoice.(stream, note) };
                        nil
                    });
                } {
                    "Satori: no SynthDef found for inst '%'".format(inst).postln;
                };
            };
        }
    };

    thisProcess.addOSCRecvFunc(~satoriHandler);
    "Satori: listening for OSC on port %".format(NetAddr.langPort).postln;

};
