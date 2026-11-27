package org.treescan.mobile;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Process;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

final class CrashLog {
    private static final int LIMIT = 50;
    private static final long RETENTION = TimeUnit.DAYS.toMillis(30);
    private static final String VERSION_TAG = "TreeScan:";
    private static final Pattern BUILD = Pattern.compile("\\d+\\.\\d+\\.\\d+(?:\\+\\d+)?");
    private static final Pattern SOURCE = Pattern.compile("android-(java|scanner|native|anr)");
    private static final Pattern TYPE = Pattern.compile(
        "[A-Za-z_$][A-Za-z0-9_.$]{0,127}|signal [0-9]{1,2}"
            + "|Native crash \\(-?\\d+\\)|Application not responding|Unhandled Java exception");
    private static final Pattern PROJECT_FRAME = Pattern.compile(
        "org\\.treescan\\.mobile\\.[A-Za-z0-9_.$<>]{1,160}:-?\\d+");
    private final Context context;
    private final File folder;
    private final String version;

    CrashLog(Context context) {
        this.context = context;
        folder = new File(context.getFilesDir(), "crash-reports");
        version = versionName(context);
    }

    @SuppressWarnings("deprecation")
    private static String versionName(Context context) {
        try {
            PackageInfo info = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            long build = Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
            return info.versionName + "+" + build;
        } catch (PackageManager.NameNotFoundException missing) {
            return "unknown";
        }
    }

    void install() {
        Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        if (previous != null) {
            Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
                try {
                    String frame = null;
                    for (StackTraceElement element : error.getStackTrace()) {
                        if (!element.getClassName().startsWith("org.treescan.mobile.")) continue;
                        frame = element.getClassName() + "." + element.getMethodName() +
                            ":" + element.getLineNumber();
                        break;
                    }
                    record("android-java", error.getClass().getName(), frame);
                } catch (Throwable ignored) {
                    // The system's original handler still owns process termination.
                } finally {
                    previous.uncaughtException(thread, error);
                }
            });
        }
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                ActivityManager manager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
                manager.setProcessStateSummary((VERSION_TAG + version).getBytes(StandardCharsets.UTF_8));
            } catch (RuntimeException ignored) {
                // Attach the build to system exit records where supported.
            }
        }
    }

    void recordScannerExit(int exit) {
        switch (exit) {
            case 132: case 134: case 135: case 136: case 139:
                record("android-scanner", "signal " + (exit - 128), null);
                break;
            default:
                break;
        }
    }

    private static JSONObject event(long at, String version, String source, String type, String frame)
            throws JSONException {
        JSONObject item = new JSONObject();
        item.put("schemaVersion", 1);
        item.put("timestampMs", at);
        item.put("platform", "android");
        item.put("version", version);
        item.put("source", source);
        item.put("type", type);
        if (frame != null) item.put("frame", frame);
        return item;
    }

    private void record(String source, String type, String frame) {
        long now = System.currentTimeMillis();
        String basename = "app-" + now + "-" + Process.myPid() + "-" + System.nanoTime();
        File pending = new File(folder, basename + ".tmp");
        try {
            if (!folder.isDirectory() && !folder.mkdirs() && !folder.isDirectory()) return;
            JSONObject item = event(now, version, source, type, frame);
            item.put("pid", Process.myPid());
            try (FileOutputStream output = new FileOutputStream(pending)) {
                output.write(item.toString().getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            if (pending.renameTo(new File(folder, basename + ".json"))) {
                localEvents(now - RETENTION);
            }
        } catch (IOException | JSONException | RuntimeException ignored) {
            // Record best effort. A full disk must not disrupt the original failure.
        } finally {
            if (pending.exists()) pending.delete();
        }
    }

    private List<JSONObject> localEvents(long cutoff) {
        List<JSONObject> records = new ArrayList<>();
        File[] files = folder.listFiles((dir, name) -> name.startsWith("app-") && name.endsWith(".json"));
        if (files == null) return records;
        // Each name begins with the timestamp, then the process and an in-process suffix.
        java.util.Arrays.sort(files, (left, right) -> right.getName().compareTo(left.getName()));
        for (File file : files) {
            if (file.lastModified() < cutoff || records.size() == LIMIT) {
                file.delete();
                continue;
            }
            long size = file.length();
            if (size <= 0 || size > 4096) continue;
            try (FileInputStream input = new FileInputStream(file)) {
                byte[] data = new byte[(int) size];
                int offset = 0;
                while (offset < data.length) {
                    int count = input.read(data, offset, data.length - offset);
                    if (count == -1) break;
                    offset += count;
                }
                JSONObject record = new JSONObject(new String(data, 0, offset, StandardCharsets.UTF_8));
                if (record.optInt("schemaVersion") == 1 && record.optLong("timestampMs") >= cutoff
                        && record.opt("source") instanceof String && record.opt("type") instanceof String
                        && record.opt("version") instanceof String) {
                    records.add(record);
                }
            } catch (IOException | JSONException ignored) {}
        }
        return records;
    }

    JSONObject report() throws JSONException {
        long now = System.currentTimeMillis();
        long cutoff = now - RETENTION;
        List<JSONObject> records = localEvents(cutoff);
        if (Build.VERSION.SDK_INT >= 30) includeSystemExits(records, cutoff);
        Collections.sort(records, (left, right) ->
            Long.compare(right.optLong("timestampMs"), left.optLong("timestampMs")));
        JSONArray events = new JSONArray();
        Map<String, JSONObject> groups = new LinkedHashMap<>();
        for (JSONObject record : records) {
            if (events.length() == LIMIT) break;
            long at = record.optLong("timestampMs");
            String source = safeLabel(record.getString("source"), SOURCE);
            String type = safeLabel(record.getString("type"), TYPE);
            String build = safeLabel(record.getString("version"), BUILD);
            String frame = record.optString("frame", "");
            if (!PROJECT_FRAME.matcher(frame).matches()) frame = null;
            events.put(event(at, build, source, type, frame));
            String key = source + "\0" + type + "\0" + build + "\0" + frame;
            JSONObject group = groups.get(key);
            if (group == null) {
                group = new JSONObject();
                group.put("source", source);
                group.put("type", type);
                group.put("version", build);
                if (frame != null) group.put("frame", frame);
                group.put("lastSeenMs", at);
                groups.put(key, group);
            }
            group.put("count", group.optInt("count") + 1);
        }
        JSONObject result = new JSONObject();
        result.put("format", "treescan-crash-report");
        result.put("schemaVersion", 1);
        result.put("generatedAtMs", now);
        result.put("events", events);
        result.put("groups", new JSONArray(groups.values()));
        return result;
    }

    private static String safeLabel(String value, Pattern pattern) {
        return pattern.matcher(value).matches() ? value : "unknown";
    }

    private void includeSystemExits(List<JSONObject> records, long cutoff) throws JSONException {
        try {
            ActivityManager manager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
            for (ApplicationExitInfo info : manager.getHistoricalProcessExitReasons(null, 0, LIMIT)) {
                long time = info.getTimestamp();
                if (time < cutoff || !context.getPackageName().equals(info.getProcessName())) continue;
                String source;
                String type;
                switch (info.getReason()) {
                    case ApplicationExitInfo.REASON_CRASH_NATIVE:
                        source = "android-native";
                        type = "Native crash (" + info.getStatus() + ")";
                        break;
                    case ApplicationExitInfo.REASON_ANR:
                        source = "android-anr";
                        type = "Application not responding";
                        break;
                    case ApplicationExitInfo.REASON_CRASH:
                        if (hasJavaRecord(records, info.getPid(), time)) continue;
                        source = "android-java";
                        type = "Unhandled Java exception";
                        break;
                    default:
                        continue;
                }
                byte[] data = info.getProcessStateSummary();
                String build = data == null ? "" : new String(data, StandardCharsets.UTF_8);
                build = build.startsWith(VERSION_TAG) ? build.substring(VERSION_TAG.length()) : "unknown";
                records.add(event(time, build, source, type, null));
            }
        } catch (RuntimeException ignored) {
            // Historical exit records are optional system data.
        }
    }

    private static boolean hasJavaRecord(List<JSONObject> records, int pid, long time) {
        for (JSONObject record : records) {
            if (record.optInt("pid") == pid && "android-java".equals(record.optString("source"))
                    && Math.abs(record.optLong("timestampMs") - time) <= 10000) return true;
        }
        return false;
    }
}
