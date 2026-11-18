package com.example.deepseekchat;

import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebView;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.WebViewListener;

public class MainActivity extends BridgeActivity {
    @Override public void onCreate(android.os.Bundle savedInstanceState) {
        registerPlugin(AppUpdatePlugin.class);
        registerPlugin(ExportTextPlugin.class);
        registerPlugin(DiagnosticsDevicePlugin.class);
        registerPlugin(CheckoutBrowserPlugin.class);
        super.onCreate(savedInstanceState);
        getBridge().addWebViewListener(new WebViewListener() {
            @Override
            public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                // A killed renderer leaves its WebView unusable. Recreate the activity so
                // Capacitor builds a fresh bridge and reloads the bundled application.
                runOnUiThread(MainActivity.this::recreate);
                return true;
            }
        });
    }
}
