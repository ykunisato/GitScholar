package jp.gitscholar.gitscholar

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 共有シートと github.com のリンクから渡された URL を Dart 側へ引き渡す（FR-100）。
 * 依存パッケージを増やさないため、メソッドチャネルを直接使っている。
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** Dart が受け取りに来る前に届いた URL を保持する。 */
    private var pending: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pending = linkFrom(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        result.success(pending)
                        pending = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = linkFrom(intent) ?: return
        val open = channel
        if (open == null) pending = link else open.invokeMethod("onLink", link)
    }

    private fun linkFrom(intent: Intent?): String? = when (intent?.action) {
        Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
        Intent.ACTION_VIEW -> intent.dataString
        else -> null
    }

    private companion object {
        const val CHANNEL = "jp.gitscholar/links"
    }
}
