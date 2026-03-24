s.waitForBoot {

    load(thisProcess.nowExecutingPath.dirname +/+ "synthdefs.scd");

    // Load user-defined SynthDefs if present (gitignored)
    var customPath = thisProcess.nowExecutingPath.dirname +/+ "custom-synthdefs.scd";
    if(File.exists(customPath)) { load(customPath) };


    // Reconstruct a Dictionary from interleaved [key, val, key, val, ...] OSC args
    ~parseParams = { |args|
        var dict = Dictionary.new;
        args.clump(2).do { |pair| dict[pair[0].asSymbol] = pair[1] };
        dict
    };

    // One Group per stream, created lazily on first message
    ~groups = Dictionary.new;

    ~getGroup = { |stream|
        ~groups[stream] ?? {
            var group = Group.new(s);
            ~groups[stream] = group;
            "Satori: created group for stream %".format(stream).postln;
            group
        }
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

            [stream, type, params, group].postln;
        }
    };

    thisProcess.addOSCRecvFunc(~satoriHandler);
    "Satori: listening for OSC on port %".format(NetAddr.langPort).postln;

};
