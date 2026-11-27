package org.treescan.mobile;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

final class SpaceMapView extends ViewGroup {
    interface Actions {
        void open(ScanEntry entry);
        boolean copy(ScanEntry entry);
    }

    private static final int MAX_TILES = 24;
    private static final int[] COLORS = {
        0xff2558ac, 0xff246879, 0xff3a618e, 0xff3b6857, 0xff694c86, 0xff8a4e38,
    };
    private final List<Double> weights = new ArrayList<>();
    private final List<Rect> bounds = new ArrayList<>();
    private final List<CharSequence> captions = new ArrayList<>();
    private final int gap;
    private int emptyColor = 0xff52637e;

    SpaceMapView(Context context) {
        super(context);
        gap = dp(2);
    }

    void setEmptyColor(int color) {
        emptyColor = color;
    }

    void show(List<ScanEntry> sorted, boolean allocated, String other,
              String noData, Actions actions) {
        removeAllViews();
        weights.clear();
        bounds.clear();
        captions.clear();
        double remainder = 0;
        for (ScanEntry entry : sorted) {
            long size = entry.size(allocated);
            if (size <= 0) break;
            if (getChildCount() < MAX_TILES - 1) {
                addTile(entry.name, TreeScanActivity.bytes(size), size, entry, actions);
            } else {
                remainder += size;
            }
        }
        if (remainder > 0) {
            addTile(other, TreeScanActivity.bytes((long) remainder), remainder, null, actions);
        }
        if (weights.isEmpty()) {
            TextView empty = new TextView(getContext());
            empty.setGravity(Gravity.CENTER);
            empty.setText(noData);
            empty.setTextColor(emptyColor);
            addView(empty);
        }
        requestLayout();
    }

    private void addTile(String name, String size, double weight, ScanEntry entry, Actions actions) {
        TextView tile = new TextView(getContext());
        tile.setGravity(Gravity.CENTER_VERTICAL);
        tile.setPadding(dp(8), 0, dp(8), 0);
        tile.setMaxLines(2);
        tile.setEllipsize(TextUtils.TruncateAt.END);
        tile.setTextSize(13);
        tile.setTextColor(Color.WHITE);
        GradientDrawable background = new GradientDrawable();
        background.setColor(COLORS[getChildCount() % COLORS.length]);
        background.setCornerRadius(dp(5));
        tile.setBackground(background);
        tile.setContentDescription(name + " · " + size);
        tile.setOnClickListener(view -> actions.open(entry));
        if (entry != null) tile.setOnLongClickListener(view -> actions.copy(entry));
        weights.add(weight);
        bounds.add(new Rect());
        captions.add(name + "\n" + size);
        addView(tile, new ViewGroup.LayoutParams(0, 0));
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        int width = MeasureSpec.getSize(widthSpec);
        int height = MeasureSpec.getSize(heightSpec);
        setMeasuredDimension(width, height);
        if (weights.isEmpty()) {
            if (getChildCount() > 0) getChildAt(0).measure(widthSpec, heightSpec);
            return;
        }
        layoutRange(0, weights.size(), 0, 0, width, height);
        for (int index = 0; index < weights.size(); index++) {
            Rect box = bounds.get(index);
            int innerWidth = Math.max(0, box.width() - gap);
            int innerHeight = Math.max(0, box.height() - gap);
            TextView tile = (TextView) getChildAt(index);
            CharSequence caption = innerWidth >= dp(61) && innerHeight >= dp(40)
                ? captions.get(index) : "";
            if (!TextUtils.equals(tile.getText(), caption)) tile.setText(caption);
            tile.measure(MeasureSpec.makeMeasureSpec(innerWidth, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(innerHeight, MeasureSpec.EXACTLY));
        }
    }

    private void layoutRange(int start, int end, int x, int y, int width, int height) {
        if (end == start + 1) {
            bounds.get(start).set(x, y, x + width, y + height);
            return;
        }
        double sum = 0;
        for (int i = start; i < end; i++) sum += weights.get(i);
        int split = start + 1;
        double first = weights.get(start);
        while (split < end - 1 && first + weights.get(split) / 2 < sum / 2) {
            first += weights.get(split++);
        }
        if (width >= height) {
            int part = (int) Math.round(width * first / sum);
            layoutRange(start, split, x, y, part, height);
            layoutRange(split, end, x + part, y, width - part, height);
        } else {
            int part = (int) Math.round(height * first / sum);
            layoutRange(start, split, x, y, width, part);
            layoutRange(split, end, x, y + part, width, height - part);
        }
    }

    @Override
    protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
        if (weights.isEmpty()) {
            if (getChildCount() > 0) getChildAt(0).layout(0, 0, right - left, bottom - top);
            return;
        }
        for (int index = 0; index < getChildCount(); index++) {
            View tile = getChildAt(index);
            Rect box = bounds.get(index);
            tile.layout(box.left, box.top, box.left + tile.getMeasuredWidth(),
                box.top + tile.getMeasuredHeight());
        }
    }

    private int dp(int size) {
        return Math.round(size * getResources().getDisplayMetrics().density);
    }
}
