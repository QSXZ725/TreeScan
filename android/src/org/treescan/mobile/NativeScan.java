package org.treescan.mobile;

import android.content.Context;
import android.os.CancellationSignal;
import android.util.JsonReader;
import android.util.JsonToken;

import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PushbackInputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

final class NativeScan {
    static final class Result {
        final ScanEntry root;
        final File snapshot;
        final boolean stopped;

        Result(ScanEntry root, File snapshot, boolean stopped) {
            this.root = root;
            this.snapshot = snapshot;
            this.stopped = stopped;
        }
    }

    static final class RootUnavailable extends IOException {}

    static Result run(Context context, String path, boolean asRoot, CancellationSignal token)
            throws IOException, InterruptedException {
        File scanner = new File(context.getApplicationInfo().nativeLibraryDir, "libtreescan_scan.so");
        if (!scanner.canExecute()) throw new IOException("Scan engine unavailable");
        String[] command = asRoot
            ? new String[] {"su", "-c", "test \"$(id -u)\" = 0 || exit 125; printf R; exec "
                + quote(scanner.getAbsolutePath()) + " " + quote(path) + " --control-stdin --export -"}
            : new String[] {scanner.getAbsolutePath(), path, "--control-stdin", "--export", "-"};
        File snapshot = null;
        boolean finished = false;
        Process process = null;
        try {
            try {
                process = new ProcessBuilder(command).start();
            } catch (IOException error) {
                if (asRoot) throw new RootUnavailable();
                throw error;
            }
            final Process child = process;
            token.setOnCancelListener(() -> new Thread(() -> requestStop(child), "treescan-stop").start());
            Thread errors = new Thread(() -> drain(child.getErrorStream()), "treescan-stderr");
            errors.setDaemon(true);
            errors.start();
            Result result;
            try (PushbackInputStream input = new PushbackInputStream(process.getInputStream())) {
                if (asRoot && input.read() != 'R') throw new RootUnavailable();
                int first = input.read();
                if (first == -1) {
                    recordExit(context, process.waitFor());
                    throw new IOException("The scan engine returned no results");
                }
                input.unread(first);
                // Snapshot serialization starts after the filesystem walk ends.
                snapshot = File.createTempFile("scan-", ".json", context.getCacheDir());
                try (OutputStream copy = new BufferedOutputStream(new FileOutputStream(snapshot));
                     InputStream stream = new SnapshotStream(input, copy);
                     JsonReader in = new JsonReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
                    result = readSnapshot(in, snapshot);
                    if (in.peek() != JsonToken.END_DOCUMENT) throw new IOException("Trailing snapshot data");
                }
            }
            int exit = process.waitFor();
            if (exit != 0) {
                recordExit(context, exit);
                throw new IOException("Scan engine did not complete");
            }
            finished = true;
            return result;
        } finally {
            token.setOnCancelListener(null);
            if (process != null) {
                if (!finished) {
                    requestStop(process);
                    process.destroy();
                }
                try { process.getOutputStream().close(); } catch (IOException ignored) {}
            }
            if (!finished && snapshot != null) snapshot.delete();
        }
    }

    private static String quote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }

    private static void recordExit(Context context, int exit) {
        TreeScanApplication app = (TreeScanApplication) context.getApplicationContext();
        app.crashLog.recordScannerExit(exit);
    }

    private static void requestStop(Process process) {
        try {
            OutputStream input = process.getOutputStream();
            input.write(1);
            input.flush();
        } catch (IOException ignored) {
            // The scan may have finished before this request arrived.
        }
    }

    private static void drain(InputStream stream) {
        try (InputStream input = stream) {
            byte[] buffer = new byte[2048];
            while (input.read(buffer) != -1) {}
        } catch (IOException ignored) {}
    }

    private static Result readSnapshot(JsonReader in, File snapshot) throws IOException {
        ScanEntry root = null;
        String format = null, path = null, phase = null;
        int version = 0;
        in.beginObject();
        while (in.hasNext()) {
            switch (in.nextName()) {
                case "format": format = in.nextString(); break;
                case "formatVersion": version = in.nextInt(); break;
                case "root": path = in.nextString(); break;
                case "phase": phase = in.nextString(); break;
                case "entries":
                    if (!"treescan-snapshot".equals(format) || version != 1 || path == null
                            || root != null) throw new IOException("Invalid scan snapshot");
                    root = readEntries(in, path);
                    break;
                default: in.skipValue();
            }
        }
        in.endObject();
        if (root == null || (!"complete".equals(phase) && !"cancelled".equals(phase))) {
            throw new IOException("Incomplete scan snapshot");
        }
        return new Result(root, snapshot, "cancelled".equals(phase));
    }

    private static ScanEntry readEntries(JsonReader in, String rootPath) throws IOException {
        List<ScanEntry> ancestors = new ArrayList<>();
        ScanEntry root = null;
        in.beginArray();
        while (in.hasNext()) {
            String path = null, kind = null, coverage = null;
            long[] logical = null, allocated = null;
            in.beginObject();
            while (in.hasNext()) {
                switch (in.nextName()) {
                    case "path": path = in.nextString(); break;
                    case "kind": kind = in.nextString(); break;
                    case "coverage": coverage = in.nextString(); break;
                    case "logical": logical = readSize(in); break;
                    case "allocated": allocated = readSize(in); break;
                    default: in.skipValue();
                }
            }
            in.endObject();
            if (path == null || kind == null || coverage == null) throw new IOException("Invalid scan entry");
            int depth = path.equals(".") ? 0 : 1;
            for (int offset = 0; offset < path.length(); offset++) {
                if (path.charAt(offset) == '/') depth++;
            }
            while (ancestors.size() > depth) finishEntry(ancestors);
            if (ancestors.size() != depth || (depth == 0 && root != null)) {
                throw new IOException("Invalid entry order");
            }
            ScanEntry parent = depth == 0 ? null : ancestors.get(depth - 1);
            ScanEntry entry = new ScanEntry(parent, parent == null ? rootPath :
                path.substring(path.lastIndexOf('/') + 1), kind);
            entry.coverage = coverage;
            entry.bytes = logical == null ? -1 : logical[0];
            entry.unknown = logical == null ? 0 : logical[1];
            entry.allocated = allocated == null ? -1 : allocated[0];
            entry.allocatedUnknown = allocated == null ? 0 : allocated[1];
            entry.files = kind.equals("file") ? 1 : 0;
            if (entry.directory && (coverage.equals("unreadable") || coverage.equals("pending"))) {
                entry.skipped = 1;
            }
            if (parent == null) {
                root = entry;
            } else {
                if (!parent.directory) throw new IOException("Entry parent is not a directory");
                parent.children.add(entry);
            }
            ancestors.add(entry);
        }
        in.endArray();
        while (!ancestors.isEmpty()) finishEntry(ancestors);
        return root;
    }

    private static void finishEntry(List<ScanEntry> ancestors) {
        ScanEntry entry = ancestors.remove(ancestors.size() - 1);
        if (entry.parent != null) entry.parent.accumulateCounts(entry);
    }

    private static long[] readSize(JsonReader in) throws IOException {
        if (in.peek() == JsonToken.NULL) {
            in.nextNull();
            return null;
        }
        long[] size = {0, 0};
        in.beginObject();
        while (in.hasNext()) {
            switch (in.nextName()) {
                case "bytes":
                    String digits = in.nextString();
                    if (digits.length() > 19) {
                        size[0] = Long.MAX_VALUE;
                    } else {
                        try { size[0] = Long.parseLong(digits); }
                        catch (NumberFormatException overflow) { size[0] = Long.MAX_VALUE; }
                    }
                    break;
                case "unknownFiles": size[1] = in.nextLong(); break;
                default: in.skipValue();
            }
        }
        in.endObject();
        return size;
    }

    private static final class SnapshotStream extends FilterInputStream {
        private final OutputStream copy;

        SnapshotStream(InputStream source, OutputStream copy) {
            super(source);
            this.copy = copy;
        }

        @Override
        public int read() throws IOException {
            int value = in.read();
            if (value >= 0) copy.write(value);
            return value;
        }

        @Override
        public int read(byte[] buffer, int offset, int length) throws IOException {
            int count = in.read(buffer, offset, length);
            if (count > 0) copy.write(buffer, offset, count);
            return count;
        }
    }
}
