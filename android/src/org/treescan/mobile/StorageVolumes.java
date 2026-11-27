package org.treescan.mobile;

import android.content.Context;
import android.os.Build;
import android.os.Environment;
import android.os.StatFs;
import android.os.storage.StorageManager;
import android.os.storage.StorageVolume;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

final class StorageVolumes {
    static final class Volume {
        final File path;
        final String description;
        final boolean removable;
        final long total, available, used;

        Volume(File path, String description, boolean removable) {
            this.path = path;
            this.description = description;
            this.removable = removable;
            long totalBytes = 0, availableBytes = 0, usedBytes = 0;
            if (path != null) {
                try {
                    StatFs stats = new StatFs(path.getPath());
                    totalBytes = stats.getTotalBytes();
                    availableBytes = stats.getAvailableBytes();
                    usedBytes = Math.max(0, totalBytes - stats.getFreeBytes());
                } catch (IllegalArgumentException | SecurityException ignored) {
                    // The volume may have been removed between listing and statfs.
                }
            }
            total = totalBytes;
            available = availableBytes;
            used = usedBytes;
        }
    }

    @SuppressWarnings("deprecation")
    static List<Volume> list(Context context, String internal, String external) {
        List<Volume> volumes = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 30) {
            StorageManager manager = (StorageManager) context.getSystemService(Context.STORAGE_SERVICE);
            for (StorageVolume volume : manager.getStorageVolumes()) {
                volumes.add(new Volume(volume.getDirectory(), volume.getDescription(context),
                    volume.isRemovable()));
            }
        } else {
            File primary = Environment.getExternalStorageDirectory();
            volumes.add(new Volume(primary, internal, false));
            for (File directory : context.getExternalFilesDirs(null)) {
                if (directory == null || !Environment.isExternalStorageRemovable(directory)) continue;
                File root = directory;
                for (int depth = 0; depth < 4 && root != null; depth++) root = root.getParentFile();
                if (root != null && !root.equals(primary)) volumes.add(new Volume(root, external, true));
            }
        }
        if (volumes.isEmpty()) volumes.add(new Volume(context.getFilesDir(), internal, false));
        return volumes;
    }
}
