package io.github.gauravpwagh.spanweb

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /// Page titles sent with shared text (EXTRA_SUBJECT / EXTRA_TITLE), by
    /// shared text. The share plugin passes only the text; Dart asks for the
    /// title here. Kept in memory only, and only the last few.
    private val sharedTitles = LinkedHashMap<String, String>()

    private fun rememberTitle(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim() ?: return
        val title = (intent.getStringExtra(Intent.EXTRA_SUBJECT)
            ?: intent.getStringExtra(Intent.EXTRA_TITLE))?.trim()
        if (title.isNullOrEmpty()) return
        sharedTitles[text] = title
        while (sharedTitles.size > 10) sharedTitles.remove(sharedTitles.keys.first())
    }

    override fun onNewIntent(intent: Intent) {
        // Before super, which hands the intent to the share plugin.
        rememberTitle(intent)
        super.onNewIntent(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        rememberTitle(intent)
        super.onCreate(savedInstanceState)
        // Blocks screenshots, screen recording and the app-switcher preview.
        // Debug builds skip it so the app can be screenshotted while testing.
        val debuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (!debuggable) window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "linkvault/share")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeTitle" -> result.success(sharedTitles.remove(call.arguments as String))
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "linkvault/clipboard")
            .setMethodCallHandler { call, result ->
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                when (call.method) {
                    // Copy marked sensitive: Android 13+ hides it in the
                    // clipboard preview pop-up and keyboard suggestions.
                    "copySensitive" -> {
                        val clip = ClipData.newPlainText("link", call.arguments as String)
                        clip.description.extras = PersistableBundle().apply {
                            val key = if (Build.VERSION.SDK_INT >= 33) {
                                ClipDescription.EXTRA_IS_SENSITIVE
                            } else {
                                "android.content.extra.IS_SENSITIVE"
                            }
                            putBoolean(key, true)
                        }
                        cm.setPrimaryClip(clip)
                        result.success(null)
                    }
                    // Clears only if the clipboard still holds our text.
                    "clearIf" -> {
                        val current = cm.primaryClip?.takeIf { it.itemCount > 0 }
                            ?.getItemAt(0)?.coerceToText(this)?.toString()
                        if (current == call.arguments as String) {
                            if (Build.VERSION.SDK_INT >= 28) cm.clearPrimaryClip()
                            else cm.setPrimaryClip(ClipData.newPlainText("", ""))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
