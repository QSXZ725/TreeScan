package org.treescan.mobile;

import android.util.JsonWriter;

import java.io.IOException;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Iterator;

final class DocumentSnapshot {
    static void write(OutputStream stream, String source, ScanEntry root, boolean stopped) throws IOException {
        JsonWriter out = new JsonWriter(new OutputStreamWriter(stream, StandardCharsets.UTF_8));
        out.beginObject();
        out.name("format").value("treescan-snapshot");
        out.name("formatVersion").value(1);
        out.name("platform").value("android-saf");
        out.name("root").value(source);
        out.name("phase").value(stopped ? "cancelled" : "complete");
        out.name("entries").beginArray();
        entry(out, ".", root);
        ArrayDeque<Directory> pending = new ArrayDeque<>();
        pending.addLast(new Directory("", root.children.iterator()));
        while (!pending.isEmpty()) {
            Directory node = pending.peekLast();
            if (!node.children.hasNext()) {
                pending.removeLast();
                continue;
            }
            ScanEntry child = node.children.next();
            String path = node.prefix + child.name.replace("%", "%25").replace("/", "%2F");
            entry(out, path, child);
            if (child.directory) pending.addLast(new Directory(path + "/", child.children.iterator()));
        }
        out.endArray().endObject().flush();
    }

    private static void entry(JsonWriter out, String path, ScanEntry entry) throws IOException {
        out.beginObject();
        out.name("path").value(path);
        out.name("kind").value(entry.kind);
        out.name("coverage").value(entry.coverage);
        out.name("allocated").nullValue();
        out.name("logical").beginObject();
        out.name("bytes").value(Long.toString(entry.bytes));
        out.name("unknownFiles").value(entry.unknown);
        out.endObject();
        out.name("placeholder").value(false);
        out.endObject();
    }

    private static final class Directory {
        final String prefix;
        final Iterator<ScanEntry> children;

        Directory(String prefix, Iterator<ScanEntry> children) {
            this.prefix = prefix;
            this.children = children;
        }
    }
}
