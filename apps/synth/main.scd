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
    ~voices     = Dictionary.new; // stream -> Dictionary(note -> synth)
    ~voiceOrder = Dictionary.new; // stream -> List of notes (oldest first)

    ~getGroup = { |stream|
        ~groups[stream] ?? {
            var bus   = Bus.audio(s, 2);
            var group = Group.new(s);
            Synth.new(\satoriLimiter, [\in, bus.index, \out, 0], group, \addToTail);
            ~buses[stream]  = bus;
            ~groups[stream] = group;
            "Satori: created group for stream %".format(stream).postln;
            group
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

            if(type == "event") {
                var inst = params[\inst];
                
                if(params[\cut].notNil) { ~cutStreams.(params[\cut], params[\cutr] ?? 5) };

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
