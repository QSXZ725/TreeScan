package org.treescan.mobile;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

final class ScanEntry {
    final ScanEntry parent;
    final String kind;
    final boolean directory;
    final List<ScanEntry> children;
    String name;
    String coverage = "complete";
    long bytes, files, unknown, skipped;
    long allocated = -1, allocatedUnknown;

    ScanEntry(ScanEntry parent, String name, String kind) {
        this.parent = parent;
        this.name = name;
        this.kind = kind;
        directory = kind.equals("directory");
        children = directory ? new ArrayList<>() : Collections.emptyList();
    }

    void accumulateCounts(ScanEntry child) {
        files += child.files;
        skipped += child.skipped;
    }

    void accumulateDocument(ScanEntry child) {
        accumulateCounts(child);
        bytes = child.bytes > Long.MAX_VALUE - bytes ? Long.MAX_VALUE : bytes + child.bytes;
        unknown += child.unknown;
        if (child.skipped > 0) coverage = "partial";
    }

    long size(boolean byAllocation) {
        return byAllocation ? allocated : bytes;
    }

    String path() {
        List<String> components = new ArrayList<>();
        ScanEntry entry = this;
        for (; entry.parent != null; entry = entry.parent) components.add(entry.name);
        StringBuilder path = new StringBuilder(entry.name);
        for (int i = components.size() - 1; i >= 0; i--) {
            if (path.length() == 0 || path.charAt(path.length() - 1) != '/') path.append('/');
            path.append(components.get(i));
        }
        return path.toString();
    }
}
