package com.hermesagent.hermes_android

import android.content.Context
import android.net.Uri
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewAssetLoader
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayInputStream
import java.io.IOException

/**
 * Serves the vendored noVNC tree on `https://appassets.androidplatform.net`
 * from the Flutter asset bundle. The WebView never fetches that origin: a
 * request the loader cannot answer gets a local 404, and Dart is told when
 * the page or one of its modules failed to load.
 */
object ScreenAssetHost {
    const val CHANNEL = "hermes/screen_assets"
    const val HOST = "appassets.androidplatform.net"

    /** Registers [CHANNEL] on [engine]. */
    fun register(context: Context, engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            if (call.method != "install") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val id = (call.arguments as? Number)?.toLong()
            if (id == null) {
                result.error("bad_args", "Missing web view id", null)
                return@setMethodCallHandler
            }
            val webView = WebViewFlutterAndroidExternalApi.getWebView(engine, id)
            if (webView == null) {
                result.error("missing", "Web view is not available", null)
                return@setMethodCallHandler
            }
            val loader =
                WebViewAssetLoader.Builder()
                    .setDomain(HOST)
                    .addPathHandler("/assets/novnc/", NovncHandler(context))
                    .build()
            webView.webViewClient =
                AssetClient(loader) { channel.invokeMethod("loadFailed", null) }
            result.success(null)
        }
    }
}

private class NovncHandler(context: Context) : WebViewAssetLoader.PathHandler {
    private val assets = context.assets
    private val lookup = FlutterInjector.instance().flutterLoader()

    override fun handle(path: String): WebResourceResponse? {
        if (!safe(path)) return null
        return try {
            val key = lookup.getLookupKeyForAsset("assets/novnc/$path")
            WebResourceResponse(mime(path), "utf-8", assets.open(key))
        } catch (_: IOException) {
            null
        }
    }

    private fun safe(path: String): Boolean {
        if (path.isEmpty() || path.contains('\\') || path.contains('\u0000')) return false
        return path.split('/').none { it.isEmpty() || it == "." || it == ".." }
    }

    private fun mime(path: String): String =
        when {
            path.endsWith(".html") -> "text/html"
            path.endsWith(".js") || path.endsWith(".mjs") -> "text/javascript"
            path.endsWith(".css") -> "text/css"
            path.endsWith(".json") -> "application/json"
            path.endsWith(".svg") -> "image/svg+xml"
            path.endsWith(".png") -> "image/png"
            path.endsWith(".txt") -> "text/plain"
            else -> "application/octet-stream"
        }
}

private class AssetClient(
    private val loader: WebViewAssetLoader,
    private val onLoadFailed: () -> Unit,
) : WebViewClient() {
    override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
    ): WebResourceResponse? {
        loader.shouldInterceptRequest(request.url)?.let { return it }
        // Never let a miss on the asset host reach the network.
        if (!isAsset(request.url)) return null
        return WebResourceResponse(
            "text/plain",
            "utf-8",
            404,
            "Not Found",
            emptyMap(),
            ByteArrayInputStream(ByteArray(0)),
        )
    }

    override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
    ): Boolean = !isAsset(request.url)

    @Deprecated("Required for API 24")
    override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean =
        !isAsset(Uri.parse(url))

    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        if (isNovncAsset(request.url)) onLoadFailed()
    }

    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        errorResponse: WebResourceResponse,
    ) {
        if (isNovncAsset(request.url)) onLoadFailed()
    }

    private fun isAsset(url: Uri): Boolean =
        url.scheme == "https" && url.host.equals(ScreenAssetHost.HOST, ignoreCase = true)

    private fun isNovncAsset(url: Uri): Boolean =
        isAsset(url) && url.path.orEmpty().startsWith("/assets/novnc/")
}
