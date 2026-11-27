package org.treescan.mobile;

import android.app.Activity;
import android.app.AlertDialog;
import android.Manifest;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.Environment;
import android.os.OperationCanceledException;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.View;
import android.view.ViewGroup;
import android.view.Gravity;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.animation.OvershootInterpolator;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.PopupMenu;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.text.DateFormat;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.PriorityQueue;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class TreeScanActivity extends Activity {
    private static final int PICK_DIRECTORY = 31;
    private static final int STORAGE_ACCESS = 32;
    private static final int EXPORT = 33;
    private static final int EXPORT_CRASHES = 34;
    private enum ResultView { FOLDERS, MAP, TOP }
    private static final String[] COLUMNS = {
        Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
        Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE,
    };

    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final ExecutorService viewWorker = Executors.newSingleThreadExecutor();
    private final boolean chinese = "zh".equals(Locale.getDefault().getLanguage());
    private CancellationSignal current;
    private ScanEntry root, folder;
    private File snapshot;
    private String source;
    private boolean nativeMode, rootMode, stopped, allocation;
    private ResultView resultView = ResultView.FOLDERS;
    private int inkColor, mutedColor, pageColor, cardColor;
    private LinearLayout page;
    private TextView titleView, state, heading;
    private Button choose, up, stop, metric, viewMode;
    private LinearLayout resultTools;
    private ListView rows;
    private SpaceMapView map;
    private String pendingCrashReport;
    private volatile long viewRequest;

    @Override
    protected void onCreate(Bundle savedState) {
        setTheme(isDarkMode() ? android.R.style.Theme_Material_NoActionBar
            : android.R.style.Theme_Material_Light_NoActionBar);
        super.onCreate(savedState);
        page = column();
        page.setPadding(dp(20), dp(16), dp(20), dp(12));
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            page.setOnApplyWindowInsetsListener((view, insets) -> {
                android.graphics.Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                view.setPadding(bars.left + dp(20), bars.top + dp(16),
                    bars.right + dp(20), bars.bottom + dp(12));
                return insets;
            });
        }

        titleView = label("TreeScan", 28, inkColor);
        titleView.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        titleRow.addView(titleView, new LinearLayout.LayoutParams(0,
            ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Button more = new Button(this, null, android.R.attr.borderlessButtonStyle);
        more.setText("⋮");
        more.setTextSize(22);
        more.setContentDescription(text("更多选项", "More options"));
        more.setPadding(0, 0, 0, 0);
        more.setOnClickListener(view -> {
            PopupMenu menu = new PopupMenu(this, more);
            menu.getMenu().add(text("崩溃与异常", "Crashes and errors"))
                .setOnMenuItemClickListener(item -> {
                    showCrashLog();
                    return true;
                });
            menu.show();
        });
        titleRow.addView(more, new LinearLayout.LayoutParams(dp(48), dp(48)));
        page.addView(titleRow);

        LinearLayout actions = new LinearLayout(this);
        choose = new Button(this);
        choose.setText(text("选择目录", "Choose folder"));
        choose.setOnClickListener(view -> chooseSource());
        actions.addView(choose, new LinearLayout.LayoutParams(0, dp(52), 1));
        Button storage = new Button(this, null, android.R.attr.borderlessButtonStyle);
        storage.setText(text("磁盘信息", "Disks"));
        storage.setOnClickListener(view -> showStorage());
        actions.addView(storage);
        stop = new Button(this, null, android.R.attr.borderlessButtonStyle);
        stop.setText(text("停止", "Stop"));
        stop.setOnClickListener(view -> {
            if (current != null) {
                stop.setEnabled(false);
                state.setText(text("正在停止…", "Stopping…"));
                current.cancel();
            }
        });
        actions.addView(stop);
        page.addView(actions);
        state = label(text("选择扫描位置。", "Choose a location to scan."), 14, mutedColor);
        state.setPadding(0, dp(8), 0, dp(12));
        page.addView(state);

        resultTools = new LinearLayout(this);
        metric = tool(resultTools, "", () -> {
            allocation = !allocation;
            show(folder);
        });
        viewMode = tool(resultTools, "", this::chooseView);
        tool(resultTools, text("导出", "Export"), this::pickExport);
        tool(resultTools, text("重扫", "Rescan"), () ->
            startScan(nativeMode ? null : Uri.parse(source), nativeMode ? source : null, rootMode));
        page.addView(resultTools);

        LinearLayout location = new LinearLayout(this);
        heading = label("", 19, inkColor);
        heading.setMaxLines(2);
        heading.setEllipsize(TextUtils.TruncateAt.END);
        location.addView(heading, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        up = new Button(this, null, android.R.attr.borderlessButtonStyle);
        up.setText(text("上一级", "Parent"));
        up.setOnClickListener(view -> {
            if (folder != null && folder.parent != null) show(folder.parent, true);
        });
        location.addView(up);
        page.addView(location);
        FrameLayout results = new FrameLayout(this);
        rows = new ListView(this);
        rows.setOnItemClickListener((adapter, view, position, id) -> {
            ScanEntry entry = (ScanEntry) adapter.getItemAtPosition(position);
            openEntry(entry);
        });
        rows.setOnItemLongClickListener((adapter, view, position, id) -> {
            ScanEntry entry = (ScanEntry) adapter.getItemAtPosition(position);
            return copyEntry(entry);
        });
        results.addView(rows, new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        map = new SpaceMapView(this);
        map.setVisibility(View.GONE);
        results.addView(map, new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        page.addView(results, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        setContentView(page);
        applyTheme();
        show(null);
        setScanning(false);
    }

    private boolean isDarkMode() {
        return (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
            == Configuration.UI_MODE_NIGHT_YES;
    }

    @SuppressWarnings("deprecation")
    private void applyTheme() {
        boolean dark = isDarkMode();
        inkColor = dark ? Color.rgb(232, 237, 247) : Color.rgb(28, 36, 52);
        mutedColor = dark ? Color.rgb(156, 171, 198) : Color.rgb(82, 99, 126);
        pageColor = dark ? Color.rgb(18, 22, 30) : Color.rgb(248, 250, 255);
        cardColor = dark ? Color.rgb(29, 35, 48) : Color.rgb(239, 244, 253);
        page.setBackgroundColor(pageColor);
        titleView.setTextColor(inkColor);
        heading.setTextColor(inkColor);
        state.setTextColor(mutedColor);
        map.setEmptyColor(mutedColor);
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController controller = getWindow().getInsetsController();
            if (controller != null) {
                int mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                    | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                controller.setSystemBarsAppearance(dark ? 0 : mask, mask);
            }
        } else if (Build.VERSION.SDK_INT >= 23) {
            View decor = getWindow().getDecorView();
            int flags = decor.getSystemUiVisibility();
            decor.setSystemUiVisibility(dark ? (flags & ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR)
                : (flags | View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR));
        }
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        applyTheme();
        if (folder != null) show(folder, false);
    }

    private void chooseView() {
        PopupMenu menu = new PopupMenu(this, viewMode);
        for (ResultView view : ResultView.values()) {
            menu.getMenu().add(viewLabel(view)).setOnMenuItemClickListener(item -> {
                resultView = view;
                show(folder, true);
                return true;
            });
        }
        menu.show();
    }

    private String viewLabel(ResultView view) {
        switch (view) {
            case MAP: return text("面积图", "Map");
            case TOP: return text("前 100 项", "Top 100");
            default: return text("目录", "Folders");
        }
    }

    private boolean copyEntry(ScanEntry entry) {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        clipboard.setPrimaryClip(ClipData.newPlainText(text("文件路径", "File path"), entry.path()));
        Toast.makeText(this, text("路径已复制", "Path copied"), Toast.LENGTH_SHORT).show();
        return true;
    }

    private void openEntry(ScanEntry entry) {
        if (entry.directory) {
            if (resultView == ResultView.TOP) resultView = ResultView.FOLDERS;
            show(entry, true);
        } else if (entry.kind.equals("mount") && rootMode) {
            String path = entry.path();
            new AlertDialog.Builder(this).setTitle(path)
                .setMessage(text("扫描这个挂载卷？", "Scan this mounted volume?"))
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(text("扫描", "Scan"), (dialog, button) -> startScan(null, path, true))
                .show();
        } else {
            String sizes = text("逻辑大小 ", "Logical size ") + formatSize(entry, false);
            if (nativeMode) sizes += "\n" + text("占用空间 ", "Allocated space ") + formatSize(entry, true);
            new AlertDialog.Builder(this).setTitle(entry.name)
                .setMessage(entry.path() + "\n\n" + sizes)
                .setNeutralButton(text("复制路径", "Copy path"), (dialog, button) -> copyEntry(entry))
                .setPositiveButton(android.R.string.ok, null)
                .show();
        }
    }

    private List<StorageVolumes.Volume> volumes() {
        return StorageVolumes.list(this, text("内部存储", "Internal storage"),
            text("可移动存储", "Removable storage"));
    }

    private void showStorage() {
        List<StorageVolumes.Volume> volumes = volumes();
        ScrollView scroll = new ScrollView(this);
        LinearLayout cards = column();
        cards.setPadding(dp(20), dp(10), dp(20), dp(12));
        for (StorageVolumes.Volume volume : volumes) {
            LinearLayout card = column();
            card.setPadding(dp(14), dp(12), dp(14), dp(12));
            GradientDrawable background = new GradientDrawable();
            background.setColor(cardColor);
            background.setCornerRadius(dp(13));
            card.setBackground(background);
            TextView name = label(volume.description, 17, inkColor);
            name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
            card.addView(name);
            String details = volume.removable ? text("可移动卷", "Removable volume")
                : text("内部卷", "Internal volume");
            if (volume.path != null) details += " · " + volume.path.getPath();
            card.addView(label(details, 13, mutedColor));
            if (volume.total > 0) {
                int percent = (int) Math.round(100.0 * volume.used / volume.total);
                ProgressBar meter = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
                meter.setProgress(percent);
                meter.setContentDescription(text("已用 ", "Used ") + percent + "%");
                card.addView(meter, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(18)));
                card.addView(label(text("总容量 ", "Total ") + bytes(volume.total) + "\n" +
                    text("已用 ", "Used ") + bytes(volume.used) + " (" + percent + "%) · " +
                    text("可用 ", "Available ") + bytes(volume.available), 14, inkColor));
            } else {
                card.addView(label(text("容量暂不可读取", "Capacity unavailable"), 14, mutedColor));
            }
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            params.bottomMargin = dp(10);
            cards.addView(card, params);
        }
        scroll.addView(cards);
        new AlertDialog.Builder(this).setTitle(text("磁盘信息", "Disk information"))
            .setView(scroll).setPositiveButton(android.R.string.ok, null).show();
    }

    private void showCrashLog() {
        final JSONObject report;
        try {
            report = ((TreeScanApplication) getApplication()).crashLog.report();
        } catch (JSONException error) {
            Toast.makeText(this, text("无法读取诊断记录", "Could not read diagnostics"), Toast.LENGTH_SHORT).show();
            return;
        }
        JSONArray events = report.optJSONArray("events");
        JSONArray groups = report.optJSONArray("groups");
        ScrollView scroll = new ScrollView(this);
        LinearLayout list = column();
        list.setPadding(dp(22), dp(10), dp(22), dp(12));
        list.addView(label(text("最近 30 天保留 " + events.length() + " 条记录",
            events.length() + " reports retained from the last 30 days"), 15, inkColor));
        if (groups.length() == 0) {
            list.addView(label(text("暂无崩溃或异常记录", "No crashes or errors recorded"), 14, mutedColor));
        }
        for (int i = 0; i < groups.length(); i++) {
            JSONObject group = groups.optJSONObject(i);
            TextView name = label(group.optString("type") + " × " + group.optInt("count"), 16, inkColor);
            name.setPadding(0, dp(12), 0, 0);
            list.addView(name);
            String detail = group.optString("source") + " · " + group.optString("version");
            if (group.has("frame")) detail += "\n" + group.optString("frame");
            detail += "\n" + DateFormat.getDateTimeInstance().format(new Date(group.optLong("lastSeenMs")));
            list.addView(label(detail, 13, mutedColor));
        }
        scroll.addView(list);
        new AlertDialog.Builder(this).setTitle(text("崩溃与异常", "Crashes and errors")).setView(scroll)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(text("导出 JSON", "Export JSON"), (dialog, button) -> {
                pendingCrashReport = report.toString();
                if (!createDocument(EXPORT_CRASHES, "TreeScan-crash-report.json")) {
                    pendingCrashReport = null;
                }
            })
            .show();
    }

    private Button tool(LinearLayout tools, String title, Runnable action) {
        Button button = new Button(this, null, android.R.attr.borderlessButtonStyle);
        button.setText(title);
        button.setAllCaps(false);
        button.setMinimumWidth(0);
        button.setPadding(dp(5), 0, dp(5), 0);
        button.setOnClickListener(view -> action.run());
        tools.addView(button, new LinearLayout.LayoutParams(0, dp(46), 1));
        return button;
    }

    private void chooseSource() {
        new AlertDialog.Builder(this).setTitle(text("选择扫描位置", "Choose a scan location"))
            .setItems(new String[] {
                text("通过系统选择文件夹", "Choose a folder"),
                text("扫描共享存储", "Scan shared storage"),
                text("扫描系统目录（Root）", "Scan system files (root)"),
            }, (dialog, selected) -> {
                switch (selected) {
                    case 0: pickDirectory(); break;
                    case 1: requestSharedStorage(); break;
                    case 2: pickRootPath(); break;
                    default: break;
                }
            }).show();
    }

    @SuppressWarnings("deprecation")
    private void requestSharedStorage() {
        if (Build.VERSION.SDK_INT >= 30 && !Environment.isExternalStorageManager()) {
            Intent intent = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.fromParts("package", getPackageName(), null));
            try {
                startActivityForResult(intent, STORAGE_ACCESS);
            } catch (android.content.ActivityNotFoundException error) {
                state.setText(text("请在系统设置中为 TreeScan 开启所有文件访问。", "Enable all files access for TreeScan in Settings."));
            }
        } else if (Build.VERSION.SDK_INT >= 23 && Build.VERSION.SDK_INT < 30
                && checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.READ_EXTERNAL_STORAGE}, STORAGE_ACCESS);
        } else {
            pickSharedVolume();
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == STORAGE_ACCESS && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) {
            pickSharedVolume();
        }
    }

    @SuppressWarnings("deprecation")
    private void pickSharedVolume() {
        List<File> paths = new ArrayList<>();
        List<String> names = new ArrayList<>();
        for (StorageVolumes.Volume volume : volumes()) {
            if (volume.path == null) continue;
            paths.add(volume.path);
            names.add(volume.description + "\n" + volume.path.getPath());
        }
        if (paths.isEmpty()) paths.add(Environment.getExternalStorageDirectory());
        if (paths.size() == 1) {
            startScan(null, paths.get(0).getPath(), false);
        } else {
            new AlertDialog.Builder(this).setTitle(text("选择存储卷", "Choose a storage volume"))
                .setItems(names.toArray(new String[0]), (dialog, choice) ->
                    startScan(null, paths.get(choice).getPath(), false)).show();
        }
    }

    private void pickRootPath() {
        EditText editor = new EditText(this);
        editor.setSingleLine(true);
        editor.setText("/");
        editor.setSelectAllOnFocus(true);
        LinearLayout field = column();
        field.setPadding(dp(22), 0, dp(22), 0);
        field.addView(editor);
        AlertDialog dialog = new AlertDialog.Builder(this)
            .setTitle(text("扫描系统目录（Root）", "Scan system files (root)"))
            .setMessage(text("输入绝对路径。扫描需要在 Root 管理器中授权。",
                "Enter an absolute path and approve access in your root manager."))
            .setView(field)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(text("扫描", "Scan"), null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
            String path = editor.getText().toString();
            if (!path.startsWith("/") || path.indexOf('\0') >= 0) {
                editor.setError(text("路径必须以 / 开头。", "Use a path starting with /."));
                return;
            }
            dialog.dismiss();
            startScan(null, path, true);
        }));
        dialog.show();
    }

    @SuppressWarnings("deprecation")
    private void pickDirectory() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            startActivityForResult(intent, PICK_DIRECTORY);
        } catch (android.content.ActivityNotFoundException error) {
            state.setText(text("系统没有可用的目录选择器。", "The system folder picker is unavailable."));
        }
    }

    @Override
    @SuppressWarnings("deprecation")
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == EXPORT_CRASHES) {
            String report = pendingCrashReport;
            pendingCrashReport = null;
            if (result == RESULT_OK && data != null && data.getData() != null && report != null) {
                writeCrashExport(data.getData(), report);
            }
            return;
        }
        if (request == STORAGE_ACCESS && Build.VERSION.SDK_INT >= 30) {
            if (Environment.isExternalStorageManager()) pickSharedVolume();
            return;
        }
        if (result != RESULT_OK || data == null || data.getData() == null) return;
        if (request == EXPORT) writeExport(data.getData());
        if (request == PICK_DIRECTORY) startScan(data.getData(), null, false);
    }

    private void startScan(Uri tree, String path, boolean asRoot) {
        if (current != null) return;
        File previous = snapshot;
        snapshot = null;
        root = null;
        nativeMode = path != null;
        rootMode = asRoot;
        source = path != null ? path : tree.toString();
        resultView = ResultView.FOLDERS;
        allocation = nativeMode;
        CancellationSignal token = new CancellationSignal();
        current = token;
        show(null);
        setScanning(true);
        state.setText(asRoot ? text("正在等待 Root 授权或读取目录…", "Waiting for root access or scanning…")
            : text("正在读取文件大小…", "Reading file sizes…"));
        worker.execute(() -> {
            if (previous != null) previous.delete();
            try {
                NativeScan.Result result = path != null ? NativeScan.run(this, path, asRoot, token)
                    : new NativeScan.Result(scan(tree, token), null, token.isCanceled());
                runOnUiThread(() -> {
                    if (current != token) {
                        if (result.snapshot != null) result.snapshot.delete();
                        return;
                    }
                    current = null;
                    root = result.root;
                    snapshot = result.snapshot;
                    stopped = result.stopped;
                    setScanning(false);
                    show(root, true);
                });
            } catch (IOException | RuntimeException | InterruptedException error) {
                runOnUiThread(() -> {
                    if (current != token) return;
                    current = null;
                    setScanning(false);
                    if (token.isCanceled()) {
                        state.setText(text("已停止。", "Stopped."));
                    } else if (error instanceof NativeScan.RootUnavailable) {
                        state.setText(text("Root 未授权。请在已 Root 的设备上允许 TreeScan 使用 su。",
                            "Root access denied. Grant TreeScan su access on a rooted device."));
                    } else {
                        state.setText(text("无法读取所选目录。", "Could not read the selected folder."));
                    }
                });
            }
        });
    }

    private ScanEntry scan(Uri tree, CancellationSignal token) {
        String rootId = DocumentsContract.getTreeDocumentId(tree);
        String name = text("所选目录", "Selected folder");
        ScanEntry root = new ScanEntry(null, name, "directory");
        List<PendingFolder> directories = new ArrayList<>();
        directories.add(new PendingFolder(rootId, root));
        Set<String> visited = new HashSet<>();
        visited.add(rootId);
        int index = 0;
        try {
            Uri rootDocument = DocumentsContract.buildDocumentUriUsingTree(tree, rootId);
            try (Cursor cursor = getContentResolver().query(rootDocument,
                    new String[] {Document.COLUMN_DISPLAY_NAME}, null, null, null, token)) {
                if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) root.name = cursor.getString(0);
            }
            for (; index < directories.size(); index++) {
                token.throwIfCanceled();
                PendingFolder next = directories.get(index);
                Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, next.id);
                try (Cursor cursor = getContentResolver().query(children, COLUMNS, null, null, null, token)) {
                    if (cursor == null) {
                        next.entry.skipped++;
                        next.entry.coverage = "unreadable";
                        continue;
                    }
                    int idColumn = cursor.getColumnIndex(Document.COLUMN_DOCUMENT_ID);
                    int nameColumn = cursor.getColumnIndex(Document.COLUMN_DISPLAY_NAME);
                    int mimeColumn = cursor.getColumnIndex(Document.COLUMN_MIME_TYPE);
                    int sizeColumn = cursor.getColumnIndex(Document.COLUMN_SIZE);
                    if (idColumn < 0 || mimeColumn < 0) {
                        next.entry.skipped++;
                        next.entry.coverage = "unreadable";
                        continue;
                    }
                    while (cursor.moveToNext()) {
                        token.throwIfCanceled();
                        String id = cursor.getString(idColumn);
                        String displayName = nameColumn < 0 ? null : cursor.getString(nameColumn);
                        String mime = cursor.getString(mimeColumn);
                        if (id == null) {
                            next.entry.skipped++;
                            next.entry.coverage = "partial";
                            continue;
                        }
                        boolean directory = Document.MIME_TYPE_DIR.equals(mime);
                        if (directory && !visited.add(id)) continue;
                        ScanEntry child = new ScanEntry(next.entry, displayName == null ? id : displayName,
                            directory ? "directory" : "file");
                        next.entry.children.add(child);
                        if (directory) {
                            directories.add(new PendingFolder(id, child));
                        } else {
                            long size = sizeColumn < 0 || cursor.isNull(sizeColumn) ? -1 : cursor.getLong(sizeColumn);
                            child.bytes = Math.max(0, size);
                            child.unknown = size < 0 ? 1 : 0;
                            child.files = 1;
                            next.entry.accumulateDocument(child);
                        }
                    }
                } catch (OperationCanceledException stopped) {
                    throw stopped;
                } catch (SecurityException | IllegalArgumentException denied) {
                    next.entry.skipped++;
                    next.entry.coverage = next.entry.children.isEmpty() ? "unreadable" : "partial";
                }
            }
        } catch (OperationCanceledException stopped) {
            for (; index < directories.size(); index++) {
                ScanEntry entry = directories.get(index).entry;
                entry.skipped++;
                entry.coverage = entry.children.isEmpty() ? "pending" : "partial";
            }
        }
        for (int position = directories.size() - 1; position >= 0; position--) {
            ScanEntry entry = directories.get(position).entry;
            if (entry.parent != null) entry.parent.accumulateDocument(entry);
        }
        return root;
    }

    private void show(ScanEntry entry) {
        show(entry, false);
    }

    private void show(ScanEntry entry, boolean animate) {
        long request = ++viewRequest;
        folder = entry;
        resultTools.setVisibility(entry == null ? View.GONE : View.VISIBLE);
        up.setVisibility(entry != null && entry.parent != null ? View.VISIBLE : View.GONE);
        heading.setText(entry == null ? "" : entry.path());
        rows.setAdapter(null);
        map.setVisibility(View.GONE);
        if (entry == null) {
            return;
        }
        metric.setText(allocation ? text("占用", "Allocated") : text("逻辑", "Logical"));
        metric.setEnabled(nativeMode);
        viewMode.setText(viewLabel(resultView) + " ▾");
        String summary = stopped ? text("已停止 · ", "Stopped · ") : "";
        if (nativeMode) summary += text("占用 ", "Allocated ") + formatSize(entry, true) + " · ";
        summary += text("逻辑 ", "Logical ") + formatSize(entry, false) +
            text(" · 文件 ", " · Files ") + entry.files;
        String coverage = coverage(entry);
        if (coverage != null) summary += " · " + coverage;
        if (entry.skipped > 0) summary += text(" · 跳过 ", " · Skipped ") + entry.skipped;
        state.setText(summary);
        ResultView mode = resultView;
        boolean byAllocation = allocation, ranking = mode == ResultView.TOP;
        long parentTotal = ranking && root != null ? root.size(byAllocation) : entry.size(byAllocation);
        viewWorker.execute(() -> {
            Comparator<ScanEntry> largest = (left, right) -> {
                int size = Long.compare(right.size(byAllocation), left.size(byAllocation));
                return size != 0 ? size : left.name.compareToIgnoreCase(right.name);
            };
            List<ScanEntry> visible = ranking ? largestFiles(entry, largest, request)
                : new ArrayList<>(entry.children);
            if (request != viewRequest) return;
            Collections.sort(visible, largest);
            runOnUiThread(() -> {
                if (request != viewRequest) return;
                if (mode == ResultView.MAP) {
                    rows.setVisibility(View.GONE);
                    map.setVisibility(View.VISIBLE);
                    map.show(visible, byAllocation, text("其余条目", "Other entries"),
                        text("当前目录没有可绘制的容量", "No sizes to plot in this folder"),
                        new SpaceMapView.Actions() {
                            @Override
                            public void open(ScanEntry selected) {
                                if (selected != null) {
                                    openEntry(selected);
                                } else {
                                    resultView = ResultView.FOLDERS;
                                    show(folder, true);
                                }
                            }
                            @Override
                            public boolean copy(ScanEntry selected) { return copyEntry(selected); }
                        });
                    animateResult(map, animate);
                } else {
                    rows.setVisibility(View.VISIBLE);
                    showRows(visible, byAllocation, ranking, parentTotal);
                    animateResult(rows, animate);
                }
            });
        });
    }

    private List<ScanEntry> largestFiles(ScanEntry entry, Comparator<ScanEntry> largest, long request) {
        PriorityQueue<ScanEntry> best = new PriorityQueue<>(101, Collections.reverseOrder(largest));
        ArrayDeque<ScanEntry> pending = new ArrayDeque<>(entry.children);
        while (!pending.isEmpty() && request == viewRequest) {
            ScanEntry next = pending.removeLast();
            if (next.directory) {
                pending.addAll(next.children);
            } else if (next.kind.equals("file")) {
                best.add(next);
                if (best.size() > 100) best.remove();
            }
        }
        return new ArrayList<>(best);
    }

    private void showRows(List<ScanEntry> visible, boolean byAllocation, boolean ranking, long parentTotal) {
        rows.setAdapter(new ArrayAdapter<ScanEntry>(this, android.R.layout.simple_list_item_2, visible) {
            @Override
            public View getView(int position, View recycled, ViewGroup parent) {
                View view = recycled == null ? getLayoutInflater().inflate(
                    android.R.layout.simple_list_item_2, parent, false) : recycled;
                ScanEntry item = getItem(position);
                TextView primary = view.findViewById(android.R.id.text1);
                primary.setText((ranking ? item.path() : item.name) +
                    (item.directory || (item.kind.equals("mount") && rootMode) ? "  ›" : ""));
                primary.setTextColor(inkColor);
                primary.setMaxLines(1);
                primary.setEllipsize(TextUtils.TruncateAt.END);
                TextView secondary = view.findViewById(android.R.id.text2);
                secondary.setTextColor(mutedColor);
                String note = coverage(item);
                long itemSize = item.size(byAllocation);
                String detail = formatSize(item, byAllocation);
                if (parentTotal > 0 && itemSize > 0) {
                    double pct = 100.0 * itemSize / parentTotal;
                    detail += pct < 0.1 ? " · <0.1%" : String.format(Locale.getDefault(), " · %.1f%%", pct);
                }
                secondary.setText(note == null ? detail : detail + " · " + note);
                return view;
            }
        });
    }

    private void animateResult(View view, boolean animate) {
        view.animate().cancel();
        if (animate && (Build.VERSION.SDK_INT < 26 || android.animation.ValueAnimator.areAnimatorsEnabled())) {
            view.setTranslationY(dp(12));
            view.animate().translationY(0).setDuration(340)
                .setInterpolator(new OvershootInterpolator(1.05f)).start();
        } else {
            view.setTranslationY(0);
        }
    }

    private String formatSize(ScanEntry entry, boolean byAllocation) {
        long size = entry.size(byAllocation);
        long unknown = byAllocation ? entry.allocatedUnknown : entry.unknown;
        if (size < 0 || (size == 0 && unknown > 0)) return text("大小未知", "Unknown size");
        return bytes(size) + (unknown == 0 ? "" : text(" ＋ 未知", " + unknown"));
    }

    private String coverage(ScanEntry entry) {
        if (entry.kind.equals("mount")) return text("独立挂载卷", "Separate mount");
        switch (entry.coverage) {
            case "unreadable": return text("无法读取", "Unreadable");
            case "partial": return text("部分统计", "Partial");
            case "pending": return text("未扫描", "Unscanned");
            default: return null;
        }
    }

    private void pickExport() {
        createDocument(EXPORT, "TreeScan-snapshot.json");
    }

    @SuppressWarnings("deprecation")
    private boolean createDocument(int request, String filename) {
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("application/json");
        intent.putExtra(Intent.EXTRA_TITLE, filename);
        try {
            startActivityForResult(intent, request);
            return true;
        } catch (android.content.ActivityNotFoundException error) {
            state.setText(text("系统没有可用的文件保存器。", "The system file saver is unavailable."));
            return false;
        }
    }

    private void writeCrashExport(Uri destination, String report) {
        worker.execute(() -> {
            boolean saved = false;
            try (OutputStream out = getContentResolver().openOutputStream(destination, "wt")) {
                if (out == null) throw new IOException("Export destination unavailable");
                out.write(report.getBytes(StandardCharsets.UTF_8));
                saved = true;
            } catch (IOException | RuntimeException ignored) {
                saved = false;
            }
            final boolean success = saved;
            runOnUiThread(() -> Toast.makeText(this,
                success ? text("诊断已导出", "Diagnostics exported")
                        : text("导出失败", "Export failed"), Toast.LENGTH_SHORT).show());
        });
    }

    private void writeExport(Uri destination) {
        ScanEntry result = root;
        if (result == null) return;
        File file = snapshot;
        String rootSource = source;
        boolean wasStopped = stopped;
        worker.execute(() -> {
            boolean saved = false;
            try (OutputStream output = getContentResolver().openOutputStream(destination, "wt")) {
                if (output == null) throw new IOException("Export destination unavailable");
                if (file == null) {
                    DocumentSnapshot.write(output, rootSource, result, wasStopped);
                } else {
                    try (FileInputStream input = new FileInputStream(file)) {
                        byte[] buffer = new byte[65536];
                        for (int count; (count = input.read(buffer)) != -1;) output.write(buffer, 0, count);
                    }
                }
                saved = true;
            } catch (IOException | RuntimeException ignored) {
                saved = false;
            }
            final boolean success = saved;
            runOnUiThread(() -> Toast.makeText(this,
                success ? text("已导出扫描结果", "Scan result exported")
                        : text("导出失败", "Export failed"),
                Toast.LENGTH_SHORT).show());
        });
    }

    private void setScanning(boolean scanning) {
        choose.setEnabled(!scanning);
        stop.setEnabled(scanning);
        stop.setVisibility(scanning ? View.VISIBLE : View.GONE);
    }

    private String text(String zh, String en) {
        return chinese ? zh : en;
    }

    private LinearLayout column() {
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        return layout;
    }

    private TextView label(String text, int size, int color) {
        TextView label = new TextView(this);
        label.setText(text);
        label.setTextSize(size);
        label.setTextColor(color);
        return label;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    static String bytes(long count) {
        if (count < 1024) return count + " B";
        String[] units = {"KiB", "MiB", "GiB", "TiB", "PiB", "EiB"};
        double value = count / 1024.0;
        int index = 0;
        while (value >= 1024 && index < units.length - 1) {
            index++;
            value /= 1024;
        }
        return String.format(Locale.getDefault(), "%.1f %s", value, units[index]);
    }

    @Override
    protected void onDestroy() {
        viewRequest++;
        if (current != null) {
            current.cancel();
            current = null;
        }
        File file = snapshot;
        if (file != null) worker.execute(file::delete);
        worker.shutdown();
        viewWorker.shutdown();
        super.onDestroy();
    }

    private static final class PendingFolder {
        final String id;
        final ScanEntry entry;

        PendingFolder(String id, ScanEntry entry) {
            this.id = id;
            this.entry = entry;
        }
    }

}
