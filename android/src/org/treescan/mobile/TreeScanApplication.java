package org.treescan.mobile;

import android.app.Application;

public final class TreeScanApplication extends Application {
    CrashLog crashLog;

    @Override
    public void onCreate() {
        super.onCreate();
        crashLog = new CrashLog(this);
        crashLog.install();
    }
}
