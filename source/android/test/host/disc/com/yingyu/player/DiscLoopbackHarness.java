package com.yingyu.player;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Synthetic native clip-to-ISO mapping, real production Java input HTTP,
 * serialized batch reads and background output HTTP. Never loads libbluray/mpv. */
public final class DiscLoopbackHarness {
    public static void main(String[] args) throws Exception {
        DiscBridge bridge = new DiscBridge(new FlutterEngine());
        MethodChannel channel = MethodChannel.latest;
        SyntheticNative.reset(); SyntheticNative.nextHandle = 1;
        SyntheticNative.loopbackBridge = bridge;
        SyntheticNative.loopbackSize = Long.parseLong(args[2]);
        try {
            Object titles = channel.call("open", Map.of("id", args[1], "iso", true, "base", args[0])).get(3, TimeUnit.SECONDS);
            Object output = channel.call("output", Map.of("id", args[1], "clips", List.of("00001"))).get(3, TimeUnit.SECONDS);
            System.out.println("{\"titles\":" + DiscBridgeHostTest.quote(titles.toString()) + ",\"output\":" + DiscBridgeHostTest.quote(output.toString()) + "}");
            System.out.flush();
            var input = new java.io.BufferedReader(new java.io.InputStreamReader(System.in));
            for (String command; (command = input.readLine()) != null && !command.equals("close");) {
                if (!command.equals("status")) throw new IllegalArgumentException("Unknown synthetic command");
                Map<?, ?> status = (Map<?, ?>)channel.call("outputStatus", Map.of("id", args[1])).get(3, TimeUnit.SECONDS);
                StringJoiner json = new StringJoiner(",", "{", "}");
                for (var item : status.entrySet()) {
                    Object value = item.getValue();
                    json.add(DiscBridgeHostTest.quote(item.getKey().toString()) + ":" +
                        (value instanceof Number || value instanceof Boolean ? value : DiscBridgeHostTest.quote(value.toString())));
                }
                System.out.println(json); System.out.flush();
            }
            channel.call("close", Map.of("id", args[1])).get(3, TimeUnit.SECONDS);
        } finally { bridge.destroy(); }
    }
}
