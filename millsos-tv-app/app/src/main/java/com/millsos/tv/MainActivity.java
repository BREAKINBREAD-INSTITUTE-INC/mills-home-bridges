package com.millsos.tv;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * MILLS OS TV v1.0 (Oct 19 2026).
 * Shows the MILLS OS TV board full screen, with no pointer. The remote's D-pad, OK and number keys
 * go to the page as key presses (left / right = page, OK = auto on or off, 1 to 8 = jump).
 * Back closes the app. Menu reloads the board.
 * It only opens home-network addresses, and never leaves the board's own address.
 */
public class MainActivity extends Activity {

    static final String DEFAULT_URL = "http://<hub-ip>:8777/missioncontrol.html";
    static final long RETRY_MS = 15000;

    private WebView web;
    private String home;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable retry = new Runnable() {
        @Override public void run() { if (web != null) web.loadUrl(home); }
    };

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        web = new WebView(this);
        web.setBackgroundColor(Color.BLACK);
        web.setFocusable(false);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setGeolocationEnabled(false);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setDisplayZoomControls(false);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);

        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                return !sameOrigin(r.getUrl());   // true = blocked
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (r.isForMainFrame()) showOffline(String.valueOf(e.getDescription()));
            }
        });

        home = pickUrl(getIntent());
        web.loadUrl(home);
        hideBars();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        home = pickUrl(intent);
        handler.removeCallbacks(retry);
        web.loadUrl(home);
    }

    /** The address to open: from show_dashboard.sh if it's a home-network address, else the last one, else HUB. */
    private String pickUrl(Intent intent) {
        SharedPreferences prefs = getSharedPreferences("millsos", MODE_PRIVATE);
        Uri d = intent == null ? null : intent.getData();
        if (d != null && isHomeNetwork(d)) {
            String u = d.toString();
            String base = u.split("\\?")[0];
            prefs.edit().putString("url", base).apply();
            return u;
        }
        return prefs.getString("url", DEFAULT_URL);
    }

    static boolean isHomeNetwork(Uri u) {
        String scheme = u.getScheme(), host = u.getHost();
        if (host == null || !("http".equals(scheme) || "https".equals(scheme))) return false;
        return host.startsWith("192.168.") || host.startsWith("10.") || host.endsWith(".local");
    }

    private boolean sameOrigin(Uri u) {
        Uri h = Uri.parse(home);
        return u.getHost() != null && u.getHost().equals(h.getHost()) && u.getPort() == h.getPort();
    }

    private void showOffline(String why) {
        String html = "<html><body style=\"margin:0;background:#14110F;color:#EDE7DF;font-family:sans-serif;"
                + "display:flex;align-items:center;justify-content:center;height:100vh\"><div style=\"text-align:center\">"
                + "<div style=\"font-size:42px\">Can't reach the board on HUB.</div>"
                + "<div style=\"font-size:22px;color:#9A9087;margin-top:16px\">Trying again every 15 seconds. "
                + "On HUB run: cd ~/Scripts/tv &amp;&amp; bash show_dashboard.sh</div>"
                + "<div style=\"font-size:16px;color:#7A7168;margin-top:16px\">" + escape(why) + "</div></div></body></html>";
        web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
        handler.removeCallbacks(retry);
        handler.postDelayed(retry, RETRY_MS);
    }

    static String escape(String s) {
        return s == null ? "" : s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    /** Remote keys go to the page. The page's tv.html defines window.millsKey. */
    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        String key = keyName(e.getKeyCode());
        if (key == null) {
            if (e.getKeyCode() == KeyEvent.KEYCODE_MENU && e.getAction() == KeyEvent.ACTION_UP) {
                web.reload();
                return true;
            }
            return super.dispatchKeyEvent(e);     // Back, Home, volume: the TV handles them
        }
        if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0) {
            web.evaluateJavascript("window.millsKey && window.millsKey('" + key + "')", null);
        }
        return true;
    }

    static String keyName(int code) {
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_LEFT: return "ArrowLeft";
            case KeyEvent.KEYCODE_DPAD_RIGHT: return "ArrowRight";
            case KeyEvent.KEYCODE_DPAD_UP: return "ArrowUp";
            case KeyEvent.KEYCODE_DPAD_DOWN: return "ArrowDown";
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER: return "Enter";
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE: return "MediaPlayPause";
            case KeyEvent.KEYCODE_MEDIA_NEXT:
            case KeyEvent.KEYCODE_CHANNEL_UP: return "ArrowRight";
            case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
            case KeyEvent.KEYCODE_CHANNEL_DOWN: return "ArrowLeft";
            default:
                if (code >= KeyEvent.KEYCODE_0 && code <= KeyEvent.KEYCODE_9) return String.valueOf(code - KeyEvent.KEYCODE_0);
                return null;
        }
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideBars();
    }

    @SuppressWarnings("deprecation")
    private void hideBars() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacks(retry);
        if (web != null) { web.destroy(); web = null; }
        super.onDestroy();
    }
}
