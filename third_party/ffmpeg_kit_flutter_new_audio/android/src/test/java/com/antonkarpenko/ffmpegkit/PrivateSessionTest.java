package com.antonkarpenko.ffmpegkit;

import org.junit.Test;
import org.junit.BeforeClass;
import java.lang.reflect.Proxy;
import java.lang.reflect.Field;
import java.util.Date;
import java.util.Map;
import java.util.Set;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import static org.junit.Assert.*;

public class PrivateSessionTest {
    @BeforeClass public static void initNativeTestMode() { PluginTestSupport.enableTestMode(); }
    private Session session(final String... args) {
        return (Session) Proxy.newProxyInstance(Session.class.getClassLoader(), new Class<?>[]{Session.class}, (proxy, method, values) -> {
            switch (method.getName()) {
                case "getArguments": return args;
                case "getCommand": return String.join(" ", args);
                case "getSessionId": return 7L;
                case "getCreateTime": case "getStartTime": return new Date(0);
                case "isFFmpeg": return true;
                case "isFFprobe": case "isMediaInformation": return false;
                default: throw new AssertionError(method.getName());
            }
        });
    }

    @Test public void sensitiveAndNormalSessionsRemainIsolatedConcurrently() throws Exception {
        final Session sensitive = session("-decryption_key", "fictional-secret", "-i", "audio");
        final Session normal = session("-i", "normal-audio");
        final ExecutorService pool = Executors.newFixedThreadPool(2);
        try {
            Future<Map<String, Object>> a = pool.submit(() -> FFmpegKitFlutterPlugin.toMap(sensitive));
            Future<Map<String, Object>> b = pool.submit(() -> FFmpegKitFlutterPlugin.toMap(normal));
            assertTrue(FFmpegKitFlutterPlugin.isPrivateSession(sensitive));
            assertFalse(FFmpegKitFlutterPlugin.isPrivateSession(normal));
            assertFalse(a.get().toString().contains("fictional-secret"));
            assertTrue(b.get().toString().contains("normal-audio"));
        } finally { pool.shutdownNow(); }
    }

    @Test public void unknownAndAlternateSyntaxFailClosed() {
        assertTrue(FFmpegKitFlutterPlugin.isPrivateSession(null));
        assertTrue(FFmpegKitFlutterPlugin.isPrivateSession(session("-DECRYPTION_KEY=fictional-secret")));
        assertTrue(FFmpegKitFlutterPlugin.isPrivateSession(session((String) null)));
    }

    @Test public void twoEnginesReceiveOnlyNormalLogsAndLateUnknownIsDropped() throws Exception {
        final FFmpegKitFlutterPlugin first = new FFmpegKitFlutterPlugin();
        final FFmpegKitFlutterPlugin second = new FFmpegKitFlutterPlugin();
        first.init(new PluginTestSupport.Messenger(), null);
        second.init(new PluginTestSupport.Messenger(), null);
        final List<Object> events1 = new CopyOnWriteArrayList<>();
        final List<Object> events2 = new CopyOnWriteArrayList<>();
        first.onListen(null, sink(events1));
        second.onListen(null, sink(events2));
        Field attached = FFmpegKitFlutterPlugin.class.getDeclaredField("attachedPlugins");
        attached.setAccessible(true);
        @SuppressWarnings("unchecked") Set<FFmpegKitFlutterPlugin> plugins = (Set<FFmpegKitFlutterPlugin>) attached.get(null);
        plugins.add(first); plugins.add(second);
        Field enabled = FFmpegKitFlutterPlugin.class.getDeclaredField("logsEnabled");
        enabled.setAccessible(true);
        ((java.util.concurrent.atomic.AtomicBoolean) enabled.get(first)).set(true);
        ((java.util.concurrent.atomic.AtomicBoolean) enabled.get(second)).set(true);
        FFmpegKitFlutterPlugin.ensureGlobalCallbacksRegistered();
        Field global = FFmpegKitConfig.class.getDeclaredField("globalLogCallback");
        global.setAccessible(true);
        LogCallback callback = (LogCallback) global.get(null);
        FFmpegSession secret = FFmpegSession.create(new String[]{"-decryption_key", "fictional-secret"});
        FFmpegSession normal = FFmpegSession.create(new String[]{"-i", "normal"});
        callback.apply(new Log(secret.getSessionId(), Level.AV_LOG_ERROR, "fictional-secret"));
        callback.apply(new Log(normal.getSessionId(), Level.AV_LOG_INFO, "normal-message"));
        FFmpegKitConfig.getFFmpegSessionCompleteCallback().apply(secret);
        FFmpegKitConfig.clearSessions();
        callback.apply(new Log(secret.getSessionId(), Level.AV_LOG_ERROR, "fictional-secret-late"));
        assertTrue(PluginTestSupport.runOnMain(() -> {}, 2000));
        assertEquals(2, events1.size());
        assertEquals(2, events2.size());
        assertTrue(events1.toString().contains("normal-message"));
        assertFalse(events2.toString().contains("fictional-secret"));
        assertTrue(events2.toString().contains(String.valueOf(secret.getSessionId())));
        plugins.remove(first); plugins.remove(second);
    }

    @Test public void sensitiveLogQueriesReturnNoRawDataAndNormalQueryWorks() throws Exception {
        FFmpegKitFlutterPlugin plugin = new FFmpegKitFlutterPlugin();
        FFmpegSession secret = FFmpegSession.create(new String[]{"-decryption_key", "fictional-secret"});
        FFmpegSession normal = FFmpegSession.create(new String[]{"-i", "normal"});
        secret.addLog(new Log(secret.getSessionId(), Level.AV_LOG_ERROR, "fictional-secret"));
        normal.addLog(new Log(normal.getSessionId(), Level.AV_LOG_INFO, "normal-message"));
        PluginTestSupport.Reply logs = new PluginTestSupport.Reply(false);
        PluginTestSupport.Reply all = new PluginTestSupport.Reply(false);
        PluginTestSupport.Reply string = new PluginTestSupport.Reply(false);
        PluginTestSupport.Reply stack = new PluginTestSupport.Reply(false);
        PluginTestSupport.Reply ordinary = new PluginTestSupport.Reply(false);
        int secretId = (int) secret.getSessionId();
        plugin.abstractSessionGetLogs(secretId, logs);
        plugin.abstractSessionGetAllLogs(secretId, 0, all);
        plugin.abstractSessionGetAllLogsAsString(secretId, 0, string);
        plugin.abstractSessionGetFailStackTrace(secretId, stack);
        plugin.abstractSessionGetLogs((int) normal.getSessionId(), ordinary);
        for (PluginTestSupport.Reply reply : new PluginTestSupport.Reply[]{logs, all, string, stack, ordinary}) {
            assertTrue(reply.await(2000)); assertEquals("success", reply.kind);
        }
        assertFalse(String.valueOf(logs.value).contains("fictional-secret"));
        assertFalse(String.valueOf(all.value).contains("fictional-secret"));
        assertEquals("", string.value);
        assertNull(stack.value);
        assertTrue(String.valueOf(ordinary.value).contains("normal-message"));
    }

    private io.flutter.plugin.common.EventChannel.EventSink sink(final List<Object> events) {
        return new io.flutter.plugin.common.EventChannel.EventSink() {
            public void success(Object value) { events.add(value); }
            public void error(String code, String message, Object details) { fail(code); }
            public void endOfStream() { }
        };
    }
}
